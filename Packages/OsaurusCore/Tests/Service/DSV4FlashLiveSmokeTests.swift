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

    @Test("four-turn AIME-ish chat survives Osaurus UI Max reasoning rail")
    func fourTurnAIMEChatSurvivesUiMaxReasoningRail() async throws {
        try #require(
            MLXService.shared.handles(requestedModel: Self.requestedModel),
            "Set OSU_MODELS_DIR to the local model root or OSAURUS_DSV4_LIVE_MODEL to an installed DSV4 Flash repo name."
        )

        let prompts = [
            "AIME smoke turn 1. Compute 19 + 23. Keep any thinking short, then answer only the integer.",
            "Turn 2. Now compute 47 - 18. Keep any thinking short, then answer only the integer.",
            "Turn 3. Compute 6 * 7. Keep any thinking short, then answer only the integer.",
            "Turn 4. Compute 144 / 12. Keep any thinking short, then answer only the integer.",
        ]

        var messages: [ChatMessage] = []
        var results: [TurnResult] = []

        for (index, prompt) in prompts.enumerated() {
            messages.append(ChatMessage(role: "user", content: prompt))
            let stream = try await MLXService.shared.streamDeltas(
                messages: messages,
                parameters: Self.parameters(reasoningEffort: "max", maxTokens: 96),
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

        let tool = Self.weatherTool()

        let stream = try await MLXService.shared.streamWithTools(
            messages: [
                ChatMessage(
                    role: "user",
                    content: "Use the get_weather tool for Paris. If you call it, use location exactly Paris."
                )
            ],
            parameters: Self.parameters(reasoningEffort: "instruct", maxTokens: 96),
            stopSequences: [],
            tools: [tool],
            toolChoice: .auto,
            requestedModel: Self.requestedModel
        )

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
            #expect(invocations.invocations.contains { $0.toolName == "get_weather" })
        } catch let invocation as ServiceToolInvocation {
            print("DSV4 live tool invocation: \(invocation.toolName) \(invocation.jsonArguments)")
            #expect(invocation.toolName == "get_weather")
            #expect(invocation.jsonArguments.contains("Paris"))
        }
    }

    @Test("long 4k-context prompt stays coherent on Osaurus UI Max rail")
    func longContextMaxReasoningSmoke() async throws {
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

        let stream = try await MLXService.shared.streamDeltas(
            messages: [ChatMessage(role: "user", content: prompt)],
            parameters: Self.parameters(reasoningEffort: "max", maxTokens: 192),
            requestedModel: Self.requestedModel,
            stopSequences: []
        )
        let result = try await Self.drain(stream)
        print(Self.summaryLine(turn: 1, result: result))

        #expect(result.stopReason != "error", "DSV4 long-context smoke ended with an error stop reason.")
        #expect(!result.unclosedReasoning, "DSV4 long-context smoke ended inside an unclosed reasoning block.")
        if let tps = result.tokensPerSecond {
            #expect(tps > 0, "DSV4 long-context smoke reported non-positive tok/s: \(tps)")
        }

        let visible = result.visible.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            visible.contains(Self.longContextSentinel),
            "DSV4 long-context answer must retain the late sentinel \(Self.longContextSentinel). Visible: \(visible)"
        )
        #expect(
            !Self.hasDegenerateRepetition(visible),
            "DSV4 long-context answer shows obvious repetition degeneration. Visible: \(visible)"
        )
    }

    private static func parameters(reasoningEffort: String, maxTokens: Int) -> GenerationParameters {
        GenerationParameters(
            temperature: 0,
            maxTokens: maxTokens,
            maxTokensExplicit: true,
            topPOverride: 1,
            seed: 1234,
            modelOptions: ["reasoningEffort": .string(reasoningEffort)]
        )
    }

    private static let longContextSentinel = "ORCHID-7291"

    private static func weatherTool() -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(
                name: "get_weather",
                description: "Get weather for a city.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "location": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("location")]),
                ])
            )
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
            additionalContext: ["enable_thinking": true, "reasoning_effort": "high"]
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
