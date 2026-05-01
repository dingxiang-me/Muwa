//
// Coverage for `ModelRuntime.ensureJANGTQSidecar` — the async wrapper that
// only auto-fetches `jangtq_runtime.safetensors` when the user actually
// hits the missing-sidecar error and never speculatively otherwise.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)  // serial: tests share the static `sidecarFetcherForTests` hook
struct EnsureJANGTQSidecarTests {

    private func makeBundle(
        weightFormat: String?,
        withSidecar: Bool
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-jangtq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let wf = weightFormat {
            let json = #"{"version": 2, "weight_format": "\#(wf)"}"#
            try json.data(using: .utf8)!.write(
                to: dir.appendingPathComponent("jang_config.json")
            )
        }
        if withSidecar {
            try Data("dummy".utf8).write(
                to: dir.appendingPathComponent("jangtq_runtime.safetensors")
            )
        }
        return dir
    }

    /// Sidecar already present → fetcher MUST NOT fire.
    @Test func noFetchWhenSidecarPresent() async throws {
        let dir = try makeBundle(weightFormat: "mxtq", withSidecar: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var fetcherCallCount = 0
        ModelRuntime.sidecarFetcherForTests = { _, _ in fetcherCallCount += 1 }
        defer { ModelRuntime.sidecarFetcherForTests = nil }

        try await ModelRuntime.ensureJANGTQSidecar(
            at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
        )
        #expect(fetcherCallCount == 0)
    }

    /// Non-mxtq stamp → fetcher MUST NOT fire (no forward mismatch).
    @Test func noFetchForNonMxtqStamp() async throws {
        let dir = try makeBundle(weightFormat: "bf16", withSidecar: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        var fetcherCallCount = 0
        ModelRuntime.sidecarFetcherForTests = { _, _ in fetcherCallCount += 1 }
        defer { ModelRuntime.sidecarFetcherForTests = nil }

        try await ModelRuntime.ensureJANGTQSidecar(
            at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
        )
        #expect(fetcherCallCount == 0)
    }

    /// No jang_config.json at all (vanilla model) → fetcher MUST NOT fire.
    @Test func noFetchForVanillaModel() async throws {
        let dir = try makeBundle(weightFormat: nil, withSidecar: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        var fetcherCallCount = 0
        ModelRuntime.sidecarFetcherForTests = { _, _ in fetcherCallCount += 1 }
        defer { ModelRuntime.sidecarFetcherForTests = nil }

        try await ModelRuntime.ensureJANGTQSidecar(
            at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
        )
        #expect(fetcherCallCount == 0)
    }

    /// Inverse mismatch (sidecar present, stamp says non-mxtq) → fetcher
    /// MUST NOT fire AND original error must surface (code 3).
    @Test func noFetchOnInverseMismatch() async throws {
        let dir = try makeBundle(weightFormat: "bf16", withSidecar: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var fetcherCallCount = 0
        ModelRuntime.sidecarFetcherForTests = { _, _ in fetcherCallCount += 1 }
        defer { ModelRuntime.sidecarFetcherForTests = nil }

        var threw: NSError?
        do {
            try await ModelRuntime.ensureJANGTQSidecar(
                at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
            )
        } catch let e as NSError {
            threw = e
        }
        #expect(fetcherCallCount == 0)
        #expect(threw?.code == 3)
    }

    /// Forward mismatch + flat-layout id (no slash) → fetcher MUST NOT fire,
    /// and the original code-2 error must surface.
    @Test func noFetchForFlatLayoutId() async throws {
        let dir = try makeBundle(weightFormat: "mxtq", withSidecar: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        var fetcherCallCount = 0
        ModelRuntime.sidecarFetcherForTests = { _, _ in fetcherCallCount += 1 }
        defer { ModelRuntime.sidecarFetcherForTests = nil }

        var threw: NSError?
        do {
            try await ModelRuntime.ensureJANGTQSidecar(
                at: dir, modelId: "Some-Flat-Model", name: "Flat"
            )
        } catch let e as NSError {
            threw = e
        }
        #expect(fetcherCallCount == 0)
        #expect(threw?.code == 2)
    }

    /// Forward mismatch + canonical HF id → fetcher fires ONCE, with the
    /// dynamic URL built from the model id, and validation passes after.
    @Test func fetchesOnceWithDynamicURL() async throws {
        let dir = try makeBundle(weightFormat: "mxtq", withSidecar: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let modelId = "JANGQ-AI/Laguna-XS.2-JANGTQ"
        var capturedURL: URL?
        var capturedDest: URL?
        var fetchCount = 0
        ModelRuntime.sidecarFetcherForTests = { url, dest in
            fetchCount += 1
            capturedURL = url
            capturedDest = dest
            try Data("real-sidecar-bytes".utf8).write(to: dest)
        }
        defer { ModelRuntime.sidecarFetcherForTests = nil }

        try await ModelRuntime.ensureJANGTQSidecar(
            at: dir, modelId: modelId, name: "Laguna"
        )

        #expect(fetchCount == 1)
        #expect(
            capturedURL?.absoluteString
                == "https://huggingface.co/JANGQ-AI/Laguna-XS.2-JANGTQ/resolve/main/jangtq_runtime.safetensors"
        )
        #expect(
            capturedDest?.lastPathComponent == "jangtq_runtime.safetensors"
        )
        // Sidecar must now be on disk so the next call is a no-op.
        #expect(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("jangtq_runtime.safetensors").path
            )
        )
    }

    /// If the fetcher throws (network down, 404, etc.), the original missing-
    /// sidecar error gets wrapped as code 4 — caller can show "we tried, here's
    /// why it didn't work".
    @Test func wrapsFetchErrorAsCodeFour() async throws {
        let dir = try makeBundle(weightFormat: "mxtq", withSidecar: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        struct StubError: Error { let what: String }
        ModelRuntime.sidecarFetcherForTests = { _, _ in
            throw StubError(what: "no network")
        }
        defer { ModelRuntime.sidecarFetcherForTests = nil }

        var threw: NSError?
        do {
            try await ModelRuntime.ensureJANGTQSidecar(
                at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
            )
        } catch let e as NSError {
            threw = e
        }
        #expect(threw?.code == 4)
        #expect(threw?.domain == "ModelRuntime")
    }
}
