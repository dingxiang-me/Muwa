//
// Pattern + character edge-case coverage for the JANGTQ preflight + sidecar
// auto-fetch. Goal: prove the auto-fetch CANNOT be triggered "randomly" by
// a malformed id, a casing slip in `weight_format`, or any other spelling
// variation we've seen in shipped bundles.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("isValidHFRepoId — strict org/repo gate")
struct ValidHFRepoIdTests {

    // MARK: - Accepted

    @Test func acceptsCanonicalOrgRepo() {
        #expect(ModelRuntime.isValidHFRepoId("OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4"))
        #expect(ModelRuntime.isValidHFRepoId("JANGQ-AI/Laguna-XS.2-JANGTQ"))
        #expect(ModelRuntime.isValidHFRepoId("mlx-community/Qwen3.5-MoE"))
    }

    @Test func acceptsAllAllowedSpecialChars() {
        #expect(ModelRuntime.isValidHFRepoId("a-b_c.d/e-f_g.h"))
        #expect(ModelRuntime.isValidHFRepoId("A.B-C_D/X-Y_Z.0"))
        #expect(ModelRuntime.isValidHFRepoId("0/0"))
    }

    @Test func acceptsMixedCase() {
        #expect(ModelRuntime.isValidHFRepoId("MixedCase/EvenWeIrDeR"))
    }

    // MARK: - Rejected: structural

    @Test func rejectsEmpty() {
        #expect(!ModelRuntime.isValidHFRepoId(""))
    }

    @Test func rejectsLeadingSlash() {
        #expect(!ModelRuntime.isValidHFRepoId("/repo"))
        #expect(!ModelRuntime.isValidHFRepoId("/org/repo"))
    }

    @Test func rejectsTrailingSlash() {
        #expect(!ModelRuntime.isValidHFRepoId("org/"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo/"))
    }

    @Test func rejectsNoSlashFlatId() {
        #expect(!ModelRuntime.isValidHFRepoId("Nemotron-3-Nano-Omni"))
        #expect(!ModelRuntime.isValidHFRepoId("Foo"))
    }

    @Test func rejectsTooManySlashes() {
        #expect(!ModelRuntime.isValidHFRepoId("org/sub/repo"))
        #expect(!ModelRuntime.isValidHFRepoId("a/b/c/d"))
    }

    @Test func rejectsEmptySegments() {
        #expect(!ModelRuntime.isValidHFRepoId("/"))
        #expect(!ModelRuntime.isValidHFRepoId("//"))
        #expect(!ModelRuntime.isValidHFRepoId("org//repo"))
    }

    // MARK: - Rejected: dangerous characters

    @Test func rejectsWhitespace() {
        #expect(!ModelRuntime.isValidHFRepoId("Org Name/Repo"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo name"))
        #expect(!ModelRuntime.isValidHFRepoId(" org/repo"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo "))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo\n"))
        #expect(!ModelRuntime.isValidHFRepoId("org\t/repo"))
    }

    @Test func rejectsURLMetacharacters() {
        #expect(!ModelRuntime.isValidHFRepoId("org/repo?evil=1"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo#frag"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo&x"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo;x"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo:8080"))
        #expect(!ModelRuntime.isValidHFRepoId("org@host/repo"))
    }

    @Test func rejectsPathTraversal() {
        #expect(!ModelRuntime.isValidHFRepoId("../etc/passwd"))
        #expect(!ModelRuntime.isValidHFRepoId("org/../repo"))
        #expect(!ModelRuntime.isValidHFRepoId("..//.."))
    }

    @Test func rejectsControlAndUnicode() {
        #expect(!ModelRuntime.isValidHFRepoId("org/repo\u{0000}"))
        #expect(!ModelRuntime.isValidHFRepoId("org/répo"))
        #expect(!ModelRuntime.isValidHFRepoId("組織/レポ"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo\u{FEFF}"))
    }

    @Test func rejectsBackslashesAndQuotes() {
        #expect(!ModelRuntime.isValidHFRepoId("org\\repo"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo\""))
        #expect(!ModelRuntime.isValidHFRepoId("org/'repo"))
    }

    @Test func rejectsExtremelyLongSegments() {
        let huge = String(repeating: "a", count: 200)
        #expect(!ModelRuntime.isValidHFRepoId("\(huge)/repo"))
        #expect(!ModelRuntime.isValidHFRepoId("org/\(huge)"))
    }
}

/// Helper: build a temp bundle dir whose `jang_config.json` carries the
/// supplied raw `weight_format` value, encoded via `JSONSerialization` so
/// control characters (tabs, newlines) round-trip properly through JSON's
/// escape rules instead of producing invalid JSON.
private func makeBundle(weightFormatRaw: String?) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("osu-jangtq-edge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let raw = weightFormatRaw {
        let payload: [String: Any] = ["weight_format": raw]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: dir.appendingPathComponent("jang_config.json"))
    }
    return dir
}

@Suite struct WeightFormatNormalizationTests {

    /// All these stamp variants must be treated as JANGTQ — forward
    /// mismatch — fetcher fires (no sidecar present).
    @Test(arguments: [
        "mxtq", "MXTQ", "Mxtq", "mXtQ", " mxtq", "mxtq ", "  mxtq\n", "\tmxtq",
    ])
    func normalizesMxtqStampVariants(_ raw: String) async throws {
        let dir = try makeBundle(weightFormatRaw: raw)
        defer { try? FileManager.default.removeItem(at: dir) }

        actor FetchTracker {
            var fired = false
            func mark() { fired = true }
        }
        let tracker = FetchTracker()

        let fetcher: @Sendable (URL, URL) async throws -> Void = { _, dest in
            await tracker.mark()
            try Data("ok".utf8).write(to: dest)
        }

        try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
            try await ModelRuntime.ensureJANGTQSidecar(
                at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
            )
        }

        let fired = await tracker.fired
        #expect(fired, "stamp '\(raw)' must be recognised as JANGTQ")
    }

    /// Stamps that look JANGTQ-ish but aren't must NOT fire the fetcher.
    @Test(arguments: [
        "mx_tq", "mxtq2", "mxq", "mxt", "tq", "bf16", "fp16", "int8", "mxfp4",
        "MXFP4", "", " ",
    ])
    func doesNotFetchForNonMxtqStamps(_ raw: String) async throws {
        let dir = try makeBundle(weightFormatRaw: raw)
        defer { try? FileManager.default.removeItem(at: dir) }

        actor FetchTracker {
            var fired = false
            func mark() { fired = true }
        }
        let tracker = FetchTracker()

        let fetcher: @Sendable (URL, URL) async throws -> Void = { _, _ in
            await tracker.mark()
        }

        try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
            try await ModelRuntime.ensureJANGTQSidecar(
                at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
            )
        }

        let fired = await tracker.fired
        #expect(!fired, "stamp '\(raw)' must NOT be auto-fetched")
    }
}

@Suite struct AutoFetchGuardTests {

    private func makeMxtqBundle() throws -> URL {
        try makeBundle(weightFormatRaw: "mxtq")
    }

    /// All these ids must reach the validator's code-2 throw without ever
    /// calling the network fetcher — they fail `isValidHFRepoId`.
    @Test(arguments: [
        "",            // empty
        "/",           // bare slash
        "/foo",        // leading slash
        "foo/",        // trailing slash
        "foo",         // no slash
        "a/b/c",       // too many slashes
        "a//b",        // empty middle segment
        "a b/c",       // whitespace
        "a/b?evil=1",  // URL meta
        "a/b#frag",    // fragment
        "a/../b",      // path traversal
        "a\\b",        // backslash
        "ä/b",         // non-ASCII
    ])
    func malformedIdsDoNotTriggerFetcher(_ id: String) async throws {
        let dir = try makeMxtqBundle()
        defer { try? FileManager.default.removeItem(at: dir) }

        actor FetchTracker {
            var fired = false
            func mark() { fired = true }
        }
        let tracker = FetchTracker()

        let fetcher: @Sendable (URL, URL) async throws -> Void = { _, _ in
            await tracker.mark()
        }

        var threw: NSError?
        do {
            try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
                try await ModelRuntime.ensureJANGTQSidecar(
                    at: dir, modelId: id, name: "Foo"
                )
            }
        } catch let e as NSError {
            threw = e
        }

        let fired = await tracker.fired
        #expect(!fired, "id '\(id)' must NOT hit the network")
        #expect(threw?.code == 2, "original code-2 error must surface for id '\(id)'")
    }

    /// Race tolerance: if a concurrent writer already produced the sidecar
    /// while our fetcher was running, we accept their copy and validate.
    @Test func raceWithConcurrentWriterIsTolerated() async throws {
        let dir = try makeMxtqBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("jangtq_runtime.safetensors")

        // Simulate "another process" writing the sidecar before our fetcher
        // returns. Our fetcher sees its temp file but the dest already exists
        // — the install path must not throw.
        let fetcher: @Sendable (URL, URL) async throws -> Void = { _, _ in
            try Data("from-other-process".utf8).write(to: dest)
        }

        try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
            try await ModelRuntime.ensureJANGTQSidecar(
                at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
            )
        }

        let bytes = try Data(contentsOf: dest)
        #expect(String(data: bytes, encoding: .utf8) == "from-other-process")
    }
}
