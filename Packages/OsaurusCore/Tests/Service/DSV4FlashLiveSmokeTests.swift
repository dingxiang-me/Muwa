//
//  DSV4FlashLiveSmokeTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

private let dsv4FlashLiveSmokeEnabled: Bool = {
    switch ProcessInfo.processInfo.environment["OSAURUS_DSV4_LIVE_SMOKE"]?.lowercased() {
    case "1", "true", "yes", "on":
        return true
    default:
        return false
    }
}()

private let dsv4FlashRawMaxLiveSmokeEnabled: Bool = {
    switch ProcessInfo.processInfo.environment["OSAURUS_DSV4_RAW_MAX_LIVE_SMOKE"]?.lowercased() {
    case "1", "true", "yes", "on":
        return true
    default:
        return false
    }
}()

private let dsv4FlashStrictToolLiveSmokeEnabled: Bool = {
    switch ProcessInfo.processInfo.environment["OSAURUS_DSV4_STRICT_TOOL_LIVE_SMOKE"]?.lowercased() {
    case "1", "true", "yes", "on":
        return true
    default:
        return false
    }
}()

@Suite("DSV4 Flash live Osaurus smoke", .serialized, .enabled(if: dsv4FlashLiveSmokeEnabled))
struct DSV4FlashLiveSmokeTests {
    private struct TurnResult {
        var visible = ""
        var reasoning = ""
        var toolNames: [String] = []
        var toolArgs = ""
        var tokenCount: Int?
        var tokensPerSecond: Double?
        var unclosedReasoning = false
        var stopReason: String?

        var hasSemanticOutput: Bool {
            !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !toolNames.isEmpty
        }
    }

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    private static var requestedModel: String {
        environment["OSAURUS_DSV4_LIVE_MODEL"] ?? "deepseek-v4-flash-jangtq-k"
    }

    @Test("four-turn AIME-ish chat survives Osaurus high reasoning rail")
    func fourTurnAIMEChatSurvivesHighReasoningRail() async throws {
        try #require(
            MLXService.shared.handles(requestedModel: Self.requestedModel),
            "Set OSU_MODELS_DIR to the local model root or OSAURUS_DSV4_LIVE_MODEL to an installed DSV4 Flash repo name."
        )

        let turns: [(prompt: String, expected: String)] = [
            ("AIME smoke turn 1. Compute 19 + 23. Keep any thinking short, then answer only the integer.", "42"),
            ("Turn 2. Now compute 47 - 18. Keep any thinking short, then answer only the integer.", "29"),
            ("Turn 3. Compute 6 * 7. Keep any thinking short, then answer only the integer.", "42"),
            ("Turn 4. Compute 144 / 12. Keep any thinking short, then answer only the integer.", "12"),
        ]

        var messages: [ChatMessage] = []
        var results: [TurnResult] = []

        for (index, turn) in turns.enumerated() {
            messages.append(ChatMessage(role: "user", content: turn.prompt))
            let stream = try await MLXService.shared.streamDeltas(
                messages: messages,
                parameters: Self.parameters(reasoningEffort: "high", maxTokens: 384),
                requestedModel: Self.requestedModel,
                stopSequences: []
            )
            let result = try await Self.drain(stream)
            print(Self.summaryLine(turn: index + 1, result: result))

            #expect(result.hasSemanticOutput, "DSV4 live turn \(index + 1) produced no visible/reasoning/tool output.")
            if let tps = result.tokensPerSecond {
                #expect(tps > 0, "DSV4 live turn \(index + 1) reported non-positive tok/s: \(tps)")
            }
            #expect(
                result.stopReason != "error",
                "DSV4 live turn \(index + 1) ended with error stop reason."
            )
            #expect(
                result.stopReason == "stop",
                "DSV4 live turn \(index + 1) did not stop cleanly: \(result.stopReason ?? "nil")"
            )
            #expect(
                result.visible.trimmingCharacters(in: .whitespacesAndNewlines).contains(turn.expected),
                "DSV4 live turn \(index + 1) did not return expected answer \(turn.expected). Visible: \(result.visible)"
            )

            let assistantEcho = result.visible.isEmpty ? "[reasoning-only smoke response]" : result.visible
            messages.append(
                ChatMessage(
                    role: "assistant",
                    content: assistantEcho,
                    tool_calls: nil,
                    tool_call_id: nil,
                    reasoning_content: result.reasoning.isEmpty ? nil : result.reasoning
                )
            )
            results.append(result)
        }

        #expect(results.count == 4)
    }

    @Test("tool prompt reaches live DSV4 stream without unsupported-tool failure")
    func toolPromptReachesLiveDSV4Stream() async throws {
        try #require(
            MLXService.shared.handles(requestedModel: Self.requestedModel),
            "Set OSU_MODELS_DIR to the local model root or OSAURUS_DSV4_LIVE_MODEL to an installed DSV4 Flash repo name."
        )

        let stream = try await Self.streamSearchToolPrompt()

        do {
            let result = try await Self.drain(stream)
            print(Self.summaryLine(turn: 1, result: result))
            #expect((result.tokenCount ?? 0) > 0, "DSV4 live tool prompt did not reach terminal stats.")
            #expect(result.stopReason != "error", "DSV4 live tool prompt ended with an error stop reason.")
            if !result.hasSemanticOutput {
                print("DSV4 live tool prompt completed without unsupported-tool failure but produced no semantic delta; tokenizer regression covers DSML schema injection.")
            }
        } catch let invocations as ServiceToolInvocations {
            print("DSV4 live tool invocations: \(invocations.invocations.map(\.toolName))")
            #expect(invocations.invocations.contains { $0.toolName == "search" })
        } catch let invocation as ServiceToolInvocation {
            print("DSV4 live tool invocation: \(invocation.toolName) \(invocation.jsonArguments)")
            #expect(invocation.toolName == "search")
            #expect(invocation.jsonArguments.contains("Paris weather"))
        }
    }

    @Test(
        "strict live DSV4 DSML tool invocation gate",
        .enabled(if: dsv4FlashStrictToolLiveSmokeEnabled)
    )
    func strictToolPromptEmitsDSMLInvocation() async throws {
        try #require(
            MLXService.shared.handles(requestedModel: Self.requestedModel),
            "Set OSU_MODELS_DIR to the local model root or OSAURUS_DSV4_LIVE_MODEL to an installed DSV4 Flash repo name."
        )

        let stream = try await Self.streamSearchToolPrompt()

        do {
            let result = try await Self.drain(stream)
            print(Self.summaryLine(turn: 1, result: result))
            #expect(
                result.toolNames.contains("search"),
                "DSV4 strict live tool gate completed without a search tool invocation. This is not a supported-tool proof."
            )
            #expect(result.toolArgs.contains("Paris weather"))
        } catch let invocations as ServiceToolInvocations {
            print("DSV4 strict live tool invocations: \(invocations.invocations.map(\.toolName))")
            #expect(invocations.invocations.contains { $0.toolName == "search" })
            #expect(invocations.invocations.contains { $0.jsonArguments.contains("Paris weather") })
        } catch let invocation as ServiceToolInvocation {
            print("DSV4 strict live tool invocation: \(invocation.toolName) \(invocation.jsonArguments)")
            #expect(invocation.toolName == "search")
            #expect(invocation.jsonArguments.contains("Paris weather"))
        }
    }

    @Test(
        "raw max 4k-context DSV4 live gate",
        .enabled(if: dsv4FlashRawMaxLiveSmokeEnabled)
    )
    func rawMaxLongContextDiagnostic() async throws {
        try #require(
            MLXService.shared.handles(requestedModel: Self.requestedModel),
            "Set OSU_MODELS_DIR to the local model root or OSAURUS_DSV4_LIVE_MODEL to an installed DSV4 Flash repo name."
        )

        let prompt = Self.longContextPrompt()
        let promptTokenCount = try await Self.promptTokenCount(prompt)
        print("DSV4 long-context prompt tokens=\(promptTokenCount)")
        #expect(
            promptTokenCount >= 4_096,
            "DSV4 long-context smoke must actually cross the 4k-token boundary."
        )

        for (index, seed) in [1_234, 5_678, 9_101].enumerated() {
            let stream = try await MLXService.shared.streamDeltas(
                messages: [ChatMessage(role: "user", content: prompt)],
                parameters: Self.parameters(
                    reasoningEffort: "max",
                    maxTokens: 384,
                    temperature: 0.6,
                    topPOverride: 0.95,
                    seed: UInt64(seed)
                ),
                requestedModel: Self.requestedModel,
                stopSequences: []
            )
            let result = try await Self.drain(stream)
            print(Self.summaryLine(turn: index + 1, result: result))

            #expect(
                result.stopReason != "error",
                "DSV4 long-context run \(index + 1) ended with an error stop reason."
            )
            #expect(
                result.stopReason == "stop",
                "DSV4 long-context run \(index + 1) did not stop cleanly: \(result.stopReason ?? "nil")"
            )
            #expect(
                !result.unclosedReasoning,
                "DSV4 long-context run \(index + 1) ended inside an unclosed reasoning block."
            )
            if let tps = result.tokensPerSecond {
                #expect(tps > 0, "DSV4 long-context run \(index + 1) reported non-positive tok/s: \(tps)")
            }

            let visible = result.visible.trimmingCharacters(in: .whitespacesAndNewlines)
            let reasoning = result.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            let semantic = [visible, reasoning].joined(separator: "\n")
            #expect(
                semantic.contains(Self.longContextSentinel),
                "DSV4 long-context run \(index + 1) must retain the late sentinel \(Self.longContextSentinel). Visible: \(visible) Reasoning: \(reasoning)"
            )
            #expect(
                !Self.hasDegenerateRepetition(visible),
                "DSV4 long-context run \(index + 1) shows obvious repetition degeneration. Visible: \(visible)"
            )
            #expect(
                !visible.contains("<think>") && !visible.contains("</think>") && !visible.contains("<｜DSML｜"),
                "DSV4 visible output leaked reasoning or DSML markup. Visible: \(visible)"
            )
        }
    }

    private static func parameters(
        reasoningEffort: String,
        maxTokens: Int,
        temperature: Float? = 0,
        topPOverride: Float? = 1,
        repetitionPenalty: Float? = nil,
        seed: UInt64? = 1234
    ) -> GenerationParameters {
        GenerationParameters(
            temperature: temperature,
            maxTokens: maxTokens,
            maxTokensExplicit: true,
            topPOverride: topPOverride,
            repetitionPenalty: repetitionPenalty,
            seed: seed,
            modelOptions: ["reasoningEffort": .string(reasoningEffort)]
        )
    }

    private static let longContextSentinel = "ORCHID-7291"

    private static func searchTool() -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(
                name: "search",
                description: "Web search. Split multiple queries with '||'.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "queries": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("queries")]),
                ])
            )
        )
    }

    private static func streamSearchToolPrompt() async throws -> AsyncThrowingStream<String, Error> {
        try await MLXService.shared.streamWithTools(
            messages: [
                ChatMessage(
                    role: "user",
                    content: "Search for current Paris weather. You must call the search tool with queries exactly Paris weather. Do not answer with plain text."
                )
            ],
            parameters: Self.parameters(
                reasoningEffort: "high",
                maxTokens: 192,
                temperature: 0,
                topPOverride: 1
            ),
            stopSequences: [],
            tools: [Self.searchTool()],
            toolChoice: .auto,
            requestedModel: Self.requestedModel
        )
    }

    private static func longContextPrompt() -> String {
        let filler = (1...180)
            .map { index in
                "Ledger row \(index): archive filler alpha beta gamma delta epsilon zeta; this row is irrelevant to the final answer."
            }
            .joined(separator: "\n")

        return """
        You are checking whether a long context remains coherent. Read the entire context, ignore filler rows, and answer the final question exactly.

        \(filler)

        Late binding fact: the release verification code is \(longContextSentinel).

        Final question: What is the release verification code? Keep any thinking very short. Answer with only the code.
        """
    }

    private static func promptTokenCount(_ prompt: String) async throws -> Int {
        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: Self.liveModelURL())
        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": prompt]],
            tools: nil,
            additionalContext: ["enable_thinking": true, "reasoning_effort": "max"]
        )
        return tokenIds.count
    }

    private static func liveModelURL() -> URL {
        if let path = environment["OSAURUS_DSV4_TEST_MODEL"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        let root = environment["OSU_MODELS_DIR"] ?? "/Users/eric/models"
        return URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("JANGQ", isDirectory: true)
            .appendingPathComponent("DeepSeek-V4-Flash-JANGTQ-K", isDirectory: true)
    }

    private static func hasDegenerateRepetition(_ text: String) -> Bool {
        let words = text
            .split { $0.isWhitespace || $0.isNewline }
            .map(String.init)
        guard words.count >= 8 else { return false }

        var previous = words[0]
        var run = 1
        for word in words.dropFirst() {
            if word.caseInsensitiveCompare(previous) == .orderedSame {
                run += 1
                if run >= 6 { return true }
            } else {
                previous = word
                run = 1
            }
        }
        return false
    }

    private static func drain(_ stream: AsyncThrowingStream<String, Error>) async throws -> TurnResult {
        var result = TurnResult()
        for try await delta in stream {
            if let stats = StreamingStatsHint.decode(delta) {
                result.tokenCount = stats.tokenCount
                result.tokensPerSecond = stats.tokensPerSecond
                result.unclosedReasoning = stats.unclosedReasoning
                result.stopReason = stats.stopReason
                continue
            }
            if let reasoning = StreamingReasoningHint.decode(delta) {
                result.reasoning += reasoning
                continue
            }
            if let toolName = StreamingToolHint.decode(delta) {
                result.toolNames.append(toolName)
                continue
            }
            if let args = StreamingToolHint.decodeArgs(delta) {
                result.toolArgs += args
                continue
            }
            if StreamingToolHint.isSentinel(delta) {
                continue
            }
            result.visible += delta
        }
        return result
    }

    private static func summaryLine(turn: Int, result: TurnResult) -> String {
        let visible = result.visible.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoning = result.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewSource = visible.isEmpty ? reasoning : visible
        let preview = String(previewSource.prefix(160)).replacingOccurrences(of: "\n", with: " ")
        let stats: String
        if let tokenCount = result.tokenCount, let tps = result.tokensPerSecond {
            stats = "tokens=\(tokenCount) tps=\(String(format: "%.2f", tps)) stop=\(result.stopReason ?? "nil") unclosed=\(result.unclosedReasoning)"
        } else {
            stats = "tokens=nil tps=nil stop=\(result.stopReason ?? "nil") unclosed=\(result.unclosedReasoning)"
        }
        return "DSV4 live turn \(turn): \(stats) visibleChars=\(visible.count) reasoningChars=\(reasoning.count) tools=\(result.toolNames) preview=\(preview)"
    }
}
