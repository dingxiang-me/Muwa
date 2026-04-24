//
//  GenerationEventMapperTests.swift
//  osaurusTests
//
//  Tests for `GenerationEventMapper` — translates vmlx-swift-lm `Generation`
//  events into osaurus `ModelRuntimeEvent`. Tool-call parsing, reasoning
//  extraction, and text-level stop matching are all owned by vmlx; these
//  tests only exercise the bridge.
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("GenerationEventMapper bridge behaviour")
struct GenerationEventMapperTests {

    private func makeStream(_ events: [Generation]) -> AsyncStream<Generation> {
        AsyncStream { continuation in
            for ev in events { continuation.yield(ev) }
            continuation.finish()
        }
    }

    private func collect(
        events: [Generation],
        supportsThinking: Bool = true
    ) async throws -> [ModelRuntimeEvent] {
        let stream = makeStream(events)
        let mapped = GenerationEventMapper.map(
            events: stream,
            supportsThinking: supportsThinking
        )
        var out: [ModelRuntimeEvent] = []
        for try await ev in mapped { out.append(ev) }
        return out
    }

    @Test func chunk_passes_through_as_tokens() async throws {
        let events: [Generation] = [
            .chunk("Hello, "),
            .chunk("world!"),
        ]
        let out = try await collect(events: events)
        var assembled = ""
        for ev in out {
            if case .tokens(let s) = ev { assembled += s }
        }
        #expect(assembled == "Hello, world!")
    }

    @Test func toolCall_emits_serialized_arguments() async throws {
        // ToolCall.Function only exposes
        //   `init(name:, arguments: [String: any Sendable])`
        // which internally maps each value through `JSONValue.from(_:)`.
        // Pass primitive Sendable values so the conversion picks the
        // matching JSONValue case (string/int/...).
        let args: [String: any Sendable] = [
            "q": "hi",
            "n": 3,
        ]
        let call = MLXLMCommon.ToolCall(
            function: MLXLMCommon.ToolCall.Function(
                name: "lookup",
                arguments: args
            )
        )
        let events: [Generation] = [.toolCall(call)]
        let out = try await collect(events: events)
        guard case .toolInvocation(let name, let argsJSON) = out.first else {
            Issue.record("expected toolInvocation, got \(String(describing: out.first))")
            return
        }
        #expect(name == "lookup")
        // JSON is unordered; assert by parsing back.
        let parsed = try JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]
        #expect(parsed?["q"] as? String == "hi")
        #expect((parsed?["n"] as? Int) == 3 || (parsed?["n"] as? Double) == 3.0)
    }

    @Test func info_emits_completionInfo() async throws {
        let info = GenerateCompletionInfo(
            promptTokenCount: 12,
            generationTokenCount: 8,
            promptTime: 0.1,
            generationTime: 0.2
        )
        let events: [Generation] = [.chunk("ok"), .info(info)]
        let out = try await collect(events: events)
        guard case .completionInfo(let count, let tps) = out.last else {
            Issue.record("expected completionInfo at end, got \(String(describing: out.last))")
            return
        }
        #expect(count == 8)
        #expect(tps > 0)
    }

    @Test func empty_chunks_are_ignored() async throws {
        let events: [Generation] = [.chunk(""), .chunk("text"), .chunk("")]
        let out = try await collect(events: events)
        let texts: [String] = out.compactMap {
            if case .tokens(let s) = $0 { return s } else { return nil }
        }
        #expect(texts == ["text"])
    }

    @Test func reasoning_event_emits_reasoning_runtime_event() async throws {
        // vmlx-swift-lm's BatchEngine emits `Generation.reasoning(String)`
        // deltas on a separate channel from `.chunk`. The mapper must
        // forward each one as `ModelRuntimeEvent.reasoning` while keeping
        // chunk tokens on the `.tokens` channel.
        let events: [Generation] = [
            .reasoning("alpha"),
            .reasoning("beta"),
            .chunk("answer"),
        ]
        let out = try await collect(events: events)

        var reasoningPieces: [String] = []
        var tokenPieces: [String] = []
        for ev in out {
            switch ev {
            case .reasoning(let s): reasoningPieces.append(s)
            case .tokens(let s): tokenPieces.append(s)
            default: continue
            }
        }
        #expect(reasoningPieces == ["alpha", "beta"])
        #expect(tokenPieces == ["answer"])
    }

    @Test func empty_reasoning_is_skipped() async throws {
        let events: [Generation] = [
            .reasoning(""),
            .reasoning("kept"),
            .reasoning(""),
        ]
        let out = try await collect(events: events)
        let reasoning: [String] = out.compactMap {
            if case .reasoning(let s) = $0 { return s } else { return nil }
        }
        #expect(reasoning == ["kept"])
    }

    // MARK: - supportsThinking: false coercion (LFM false-thinking-block fix)

    /// When the caller asserts the model does NOT emit CoT (e.g. LFM2,
    /// LFM2-MoE, classic Llama instruct), vmlx's reasoning-parser heuristic
    /// may still route the model's first bytes through `.reasoning` events
    /// because `think_xml` with `startInReasoning: true` is the fallback
    /// branch. The mapper must re-label those as `.tokens` so the osaurus UI
    /// renders them in the response block, not the think pane.
    @Test func nonThinking_reasoning_coerces_to_tokens() async throws {
        let events: [Generation] = [
            .reasoning("The capital of France is Paris."),
        ]
        let out = try await collect(events: events, supportsThinking: false)

        // No `.reasoning` events should leak out — every reasoning delta
        // gets re-classified as visible tokens.
        let reasoningPieces: [String] = out.compactMap {
            if case .reasoning(let s) = $0 { return s } else { return nil }
        }
        #expect(reasoningPieces.isEmpty)

        let tokenPieces: [String] = out.compactMap {
            if case .tokens(let s) = $0 { return s } else { return nil }
        }
        #expect(tokenPieces == ["The capital of France is Paris."])
    }

    @Test func nonThinking_mixed_chunks_and_reasoning_interleave_as_tokens() async throws {
        // In practice vmlx rarely emits a mix of `.chunk` and `.reasoning`
        // for a non-thinking model — but if it does (e.g. a template that
        // briefly enters / exits the reasoning parser's state), the
        // coerced output must preserve the ORIGINAL delivery order so the
        // answer reads coherently.
        let events: [Generation] = [
            .reasoning("Let me think. "),
            .chunk("The answer is 42."),
            .reasoning(" Done."),
        ]
        let out = try await collect(events: events, supportsThinking: false)

        let tokenPieces: [String] = out.compactMap {
            if case .tokens(let s) = $0 { return s } else { return nil }
        }
        // Order preserved: reasoning → chunk → reasoning, all coerced to tokens.
        #expect(tokenPieces == ["Let me think. ", "The answer is 42.", " Done."])
    }

    @Test func nonThinking_still_skips_empty_reasoning_deltas() async throws {
        let events: [Generation] = [
            .reasoning(""),
            .reasoning("kept"),
            .reasoning(""),
        ]
        let out = try await collect(events: events, supportsThinking: false)
        let tokenPieces: [String] = out.compactMap {
            if case .tokens(let s) = $0 { return s } else { return nil }
        }
        // Empty reasoning deltas are filtered BEFORE the coercion branch,
        // matching `.chunk` behaviour for empty strings.
        #expect(tokenPieces == ["kept"])
    }

    @Test func supportsThinking_true_is_default_and_forwards_reasoning_unchanged() async throws {
        // Guard against a future caller that flips the default accidentally —
        // the public overload must keep `supportsThinking: true` as its default.
        let events: [Generation] = [.reasoning("think-text")]
        let out = try await collect(events: events)  // uses default
        let reasoning: [String] = out.compactMap {
            if case .reasoning(let s) = $0 { return s } else { return nil }
        }
        #expect(reasoning == ["think-text"])
    }

    @Test func toolCall_serialization_failure_emits_error_envelope() async throws {
        // `JSONSerialization` rejects non-finite Doubles unless
        // `.fragmentsAllowed` is passed. Feed a `Double.infinity`
        // primitive so `JSONValue.from(_:)` produces `.double(.infinity)`
        // and the mapper's `serializeArguments` hits its error-envelope
        // branch — asserting the structured error reaches the emitted
        // `argsJSON` instead of the silent `{}` fallback we used to ship.
        let args: [String: any Sendable] = [
            "value": Double.infinity
        ]
        let call = MLXLMCommon.ToolCall(
            function: MLXLMCommon.ToolCall.Function(
                name: "broken",
                arguments: args
            )
        )
        let out = try await collect(events: [.toolCall(call)])
        guard case .toolInvocation(let name, let argsJSON) = out.first else {
            Issue.record("expected toolInvocation, got \(String(describing: out.first))")
            return
        }
        #expect(name == "broken")
        #expect(argsJSON.contains("\"_error\":\"argument_serialization_failed\""))
        #expect(argsJSON.contains("\"_tool\":\"broken\""))
    }
}
