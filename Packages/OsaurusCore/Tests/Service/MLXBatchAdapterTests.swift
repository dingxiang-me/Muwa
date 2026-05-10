//
//  MLXBatchAdapterTests.swift
//  osaurus
//
//  Coverage for the parts of `MLXBatchAdapter` that don't require a loaded
//  MLX model. End-to-end engine submission/streaming is covered by the
//  upstream `BatchEngineTests` in vmlx-swift-lm — duplicating those would
//  drag in a multi-GB model download per CI run.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct MLXBatchAdapterTests {

    /// The default flipped from 4 → 1 so the vmlx compile path engages
    /// (Stage 1B.3 promotion gates require `maxBatchSize == 1`). See the
    /// `mlxBatchEngineMaxBatchSize` doc comment in InferenceFeatureFlags
    /// for the full rationale + the pending Stage 1B.4 work that would
    /// lift the constraint. If you change the default again, update both
    /// this test AND the doc comment so they stay aligned.
    @Test func maxBatchSize_defaultsToOne_forCompileEngagement() {
        let defaults = isolatedDefaults()
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(in: defaults) == 1)
    }

    @Test func maxBatchSize_respectsUserDefaults() {
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        let defaults = isolatedDefaults()
        defaults.set(8, forKey: key)
        // Server deployments override to multi-slot at the cost of the
        // compile path — same value the test pinned before; only the
        // default changed.
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(in: defaults) == 8)
    }

    @Test func maxBatchSize_clampsAbsurdValues() {
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        let defaults = isolatedDefaults()
        defaults.set(9999, forKey: key)
        // Clamp to 32 so a typo doesn't blow out wired memory.
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(in: defaults) == 32)
    }

    @Test func maxBatchSize_zeroFallsBackToDefault_one() {
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        let defaults = isolatedDefaults()
        defaults.set(0, forKey: key)
        // Zero is treated as "unset" — falls back to the compile-friendly
        // default of 1 (was 4 prior to fa694e9e).
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(in: defaults) == 1)
    }

    @Test func generateParameters_enableCompiledBatchDecodeForSoloDefault() {
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0,
            maxTokens: 16,
            topP: 1,
            repetitionPenalty: nil
        )

        #expect(
            params.enableCompiledBatchDecode,
            "Osaurus default maxBatchSize=1 path must opt into vmlx BatchEngine compiled decode; leaving this false is the observed half-speed path"
        )
    }

    @Test func generateParameters_canDisableCompiledBatchDecodeForMultiSlotServerMode() {
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0,
            maxTokens: 16,
            topP: 1,
            repetitionPenalty: nil,
            enableCompiledBatchDecode: false
        )

        #expect(!params.enableCompiledBatchDecode)
    }

    @Test func registry_shutdownNonexistentIsNoop() async {
        // Calling shutdown on a name that was never registered should not
        // throw or crash — important because `ModelRuntime.unload` always
        // calls it, even for models that never used the batch path.
        await MLXBatchAdapter.Registry.shared.shutdownEngine(
            for: "never-registered-\(UUID().uuidString)"
        )
    }

    @Test func additionalContext_mapsDisableThinkingToEnableThinkingKwarg() {
        let disabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(true)]
        )
        let enabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(false)]
        )
        let unspecified = GenerationParameters(temperature: nil, maxTokens: 16)
        let modelName = "OsaurusAI/Qwen3.5-30B-A3B-JANGTQ"

        #expect(
            MLXBatchAdapter.additionalContext(for: disabled, modelName: modelName)["enable_thinking"] as? Bool == false
        )
        #expect(
            MLXBatchAdapter.additionalContext(for: enabled, modelName: modelName)["enable_thinking"] as? Bool == true
        )
        #expect(
            MLXBatchAdapter.additionalContext(for: unspecified, modelName: modelName)["enable_thinking"] as? Bool
                == true
        )
    }

    @Test func additionalContext_forcesLingThinkingOff() {
        let unspecified = GenerationParameters(temperature: nil, maxTokens: 16)
        let userEnabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(false)]
        )

        for modelName in [
            "OsaurusAI/Ling-2.6-flash-MXFP4",
            "OsaurusAI/Ling-2.6-flash-JANGTQ",
            "ling-2.6-flash-jangtq",
            "JANGQ-AI/Ling-2.6-flash-JANGTQ",
        ] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] as? Bool == false
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: userEnabled,
                    modelName: modelName
                )["enable_thinking"] as? Bool == false
            )
        }

        for modelName in ["linguistics-model-7b", "darling-llm"] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] as? Bool == true
            )
        }
    }

    /// ZAYA1 (Zyphra; `model_type=zaya`) is reasoning-capable but defaults
    /// thinking off (`think_in_template=false`). When no request option is
    /// present, preserve the bundle/template default with
    /// `enable_thinking=false`; when the user/API explicitly opts in via
    /// `disableThinking=false`, pass `enable_thinking=true`.
    @Test func additionalContext_defaultsZayaThinkingOffButHonorsExplicitOptIn() {
        let unspecified = GenerationParameters(temperature: nil, maxTokens: 16)
        let userEnabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(false)]
        )

        for modelName in [
            "Zyphra/Zaya1-8B-JANGTQ4",
            "Zyphra/Zaya1-8B-MXFP4",
            "OsaurusAI/Zaya1-8B-JANGTQ2",
            "Zaya1-8B-JANGTQ4",  // bare picker form
            "zaya1-8b-mxfp4",  // case-folded picker form
            "Zyphra/Zaya-S-7B-Future",  // forward-compat dash-suffix variant
        ] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] as? Bool == false,
                "ZAYA should preserve default no-thinking template mode: \(modelName)"
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: userEnabled,
                    modelName: modelName
                )["enable_thinking"] as? Bool == true,
                "ZAYA must honor explicit thinking opt-in: \(modelName)"
            )
        }

        // Boundary regression guards: names that contain `zaya` as a
        // substring but are NOT ZAYA bundles must take the default path.
        for modelName in [
            "dataset/zayasaurus",  // `/zaya` followed by letter — not ZAYA
            "lazyaardvark",  // bare prefix `lazya`, not `zaya`
            "dazaya-llm",  // `zaya` not at boundary
            "zayasaurus-7b",  // `zaya` followed by letter at start
        ] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] as? Bool == true,
                "non-ZAYA substring match must NOT force thinking off: \(modelName)"
            )
        }
    }

    @Test func tokenizerTools_respectToolChoicePromptSurface() {
        let read = Tool(
            type: "function",
            function: ToolFunction(
                name: "read_file",
                description: "Read one file",
                parameters: .object(["type": .string("object")])
            )
        )
        let write = Tool(
            type: "function",
            function: ToolFunction(
                name: "write_file",
                description: "Write one file",
                parameters: .object(["type": .string("object")])
            )
        )
        let tools = [read, write]

        #expect(ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: nil)?.count == 2)
        #expect(ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: .auto)?.count == 2)
        // The parameter is optional, so `.none` alone would mean
        // `Optional.none` and exercise the nil/default-auto path. Spell the
        // enum case explicitly to pin OpenAI `tool_choice: "none"`.
        #expect(ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: ToolChoiceOption.none) == nil)

        let selected = ModelRuntime.makeTokenizerTools(
            tools: tools,
            toolChoice: .function(
                ToolChoiceOption.FunctionName(
                    type: "function",
                    function: ToolChoiceOption.Name(name: "write_file")
                )
            )
        )
        #expect(selected?.count == 1)
        let function = selected?.first?["function"] as? [String: any Sendable]
        #expect(function?["name"] as? String == "write_file")

        let unknown = ModelRuntime.makeTokenizerTools(
            tools: tools,
            toolChoice: .function(
                ToolChoiceOption.FunctionName(
                    type: "function",
                    function: ToolChoiceOption.Name(name: "delete_everything")
                )
            )
        )
        #expect(
            unknown == nil,
            "Unknown forced tool must not expose every schema; nil keeps the injected tool surface closed."
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "MLXBatchAdapterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
