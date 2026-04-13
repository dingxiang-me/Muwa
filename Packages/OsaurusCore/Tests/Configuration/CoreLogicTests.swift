//
//  CoreLogicTests.swift
//  osaurusTests
//
//  Unit tests for the core logic paths added across Phases A through E.
//  Complements MigrationCompatTests.swift which focuses on JSON decoder
//  backward compatibility. This file tests pure behavior — state machine
//  transitions, substitution logic, and resolver precedence — without
//  touching disk or SwiftUI.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Chip cycle state machine (Phase C M-11)

@Suite("Tools chip cycle state machine")
struct ToolsChipCycleTests {

    /// Starting from nil (follow global), first tap should produce an
    /// explicit override equal to `!globalDisabled` — i.e. the opposite
    /// of whatever the global flag currently says. This is the "first
    /// visible override" step the user sees.

    @Test("nil + global-disabled-true → false (override to enabled)")
    func nilWithGlobalDisabledTrueBecomesFalse() {
        let next = FloatingInputCard.nextToolsOverrideState(
            current: nil,
            globalDisabled: true
        )
        #expect(next == false, "first tap when tools are off globally should force them on")
    }

    @Test("nil + global-disabled-false → true (override to disabled)")
    func nilWithGlobalDisabledFalseBecomesTrue() {
        let next = FloatingInputCard.nextToolsOverrideState(
            current: nil,
            globalDisabled: false
        )
        #expect(next == true, "first tap when tools are on globally should force them off")
    }

    /// Starting from an explicit override that differs from global, second
    /// tap should move to match global — still an explicit override, but
    /// now aligned with the global state. Feedback that the tap did something.

    @Test("override=false + global=true → true (flip to match global)")
    func explicitOverrideDifferingFromGlobalFlipsToMatch() {
        let next = FloatingInputCard.nextToolsOverrideState(
            current: false,
            globalDisabled: true
        )
        #expect(next == true, "second tap should move from 'force on' to 'force off matching global'")
    }

    @Test("override=true + global=false → false (flip to match global)")
    func explicitOverrideDifferingFromGlobalFlipsToMatchFalse() {
        let next = FloatingInputCard.nextToolsOverrideState(
            current: true,
            globalDisabled: false
        )
        #expect(next == false, "second tap should move from 'force off' to 'force on matching global'")
    }

    /// Starting from an explicit override that matches global, third tap
    /// should clear back to nil (follow global). Completes the three-state cycle.

    @Test("override=true + global=true → nil (clear to follow-global)")
    func explicitOverrideMatchingGlobalClearsToNil() {
        let next = FloatingInputCard.nextToolsOverrideState(
            current: true,
            globalDisabled: true
        )
        #expect(next == nil, "third tap should clear the explicit override")
    }

    @Test("override=false + global=false → nil (clear to follow-global)")
    func explicitOverrideMatchingGlobalClearsToNilFalse() {
        let next = FloatingInputCard.nextToolsOverrideState(
            current: false,
            globalDisabled: false
        )
        #expect(next == nil, "third tap should clear the explicit override")
    }

    /// Three-tap round trip should return to nil for both starting global
    /// states. Proves the cycle length is exactly 3 and is closed.

    @Test("nil → explicit → match-global → nil round trip (global=false)")
    func roundTripGlobalFalse() {
        let step1 = FloatingInputCard.nextToolsOverrideState(current: nil, globalDisabled: false)
        let step2 = FloatingInputCard.nextToolsOverrideState(current: step1, globalDisabled: false)
        let step3 = FloatingInputCard.nextToolsOverrideState(current: step2, globalDisabled: false)
        #expect(step1 == true)
        #expect(step2 == false)
        #expect(step3 == nil, "three taps should complete the cycle back to nil")
    }

    @Test("nil → explicit → match-global → nil round trip (global=true)")
    func roundTripGlobalTrue() {
        let step1 = FloatingInputCard.nextToolsOverrideState(current: nil, globalDisabled: true)
        let step2 = FloatingInputCard.nextToolsOverrideState(current: step1, globalDisabled: true)
        let step3 = FloatingInputCard.nextToolsOverrideState(current: step2, globalDisabled: true)
        #expect(step1 == false)
        #expect(step2 == true)
        #expect(step3 == nil, "three taps should complete the cycle back to nil")
    }
}

// MARK: - TurboQuant substitution (Phase E.3)

@Suite("makeGenerateParameters TurboQuant substitution")
struct MakeGenerateParametersTests {

    /// The flagship Phase E.3 decision: osaurus defaults to TurboQuant(3,3)
    /// when the user hasn't explicitly picked a quant mode. vmlx's package
    /// default is `.none`, so there's a deliberate substitution in
    /// `ModelRuntime.makeGenerateParameters`. These tests lock that in.

    @Test("nil cacheOverrides.kvQuantMode → TurboQuant(3,3) (osaurus default)")
    func nilModeSubstitutesTurboQuant() {
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: ServerCacheConfig()
        )
        // Expected: TurboQuant with 3/3. Any other mode means the
        // substitution is broken and users are getting raw full-precision
        // KV without asking for it.
        if case .turboQuant(let keyBits, let valueBits) = params.kvMode {
            #expect(keyBits == 3, "key bits should default to 3")
            #expect(valueBits == 3, "value bits should default to 3")
        } else {
            Issue.record("expected .turboQuant default, got \(params.kvMode)")
        }
    }

    @Test("explicit .none kvQuantMode → .none (user opt-out respected)")
    func explicitNoneModeRespected() {
        var overrides = ServerCacheConfig()
        // Explicit type prefix is required here: bare `.none` resolves to
        // `Optional<CacheQuantMode>.none` (i.e. nil), which would hit the
        // substitution branch and return TurboQuant. The production code
        // avoids this ambiguity by using `CacheQuantMode.none` explicitly
        // in the ConfigurationView save path (see `CacheQuantModeChoice.optionalMode`).
        overrides.kvQuantMode = CacheQuantMode.none
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: overrides
        )
        if case .none = params.kvMode {
            // Pass — user explicitly disabled quant, no substitution.
        } else {
            Issue.record("expected .none when user explicitly opts out, got \(params.kvMode)")
        }
    }

    @Test("explicit .turboQuant with custom bits → those bits used")
    func explicitTurboQuantCustomBits() {
        var overrides = ServerCacheConfig()
        overrides.kvQuantMode = .turboQuant
        overrides.turboKeyBits = 4
        overrides.turboValueBits = 5
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: overrides
        )
        if case .turboQuant(let keyBits, let valueBits) = params.kvMode {
            #expect(keyBits == 4, "custom key bits should be honored")
            #expect(valueBits == 5, "custom value bits should be honored")
        } else {
            Issue.record("expected .turboQuant with custom bits")
        }
    }

    @Test("explicit .affine mode → .affine with configured bits")
    func explicitAffineMode() {
        var overrides = ServerCacheConfig()
        overrides.kvQuantMode = .affine
        overrides.affineKVBits = 8
        overrides.affineKVGroupSize = 128
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: overrides
        )
        if case .affine(let bits, let groupSize) = params.kvMode {
            #expect(bits == 8, "affine bits should be honored")
            #expect(groupSize == 128, "affine groupSize should be honored")
        } else {
            Issue.record("expected .affine, got \(params.kvMode)")
        }
    }

    @Test("explicit .affine mode without bits → defaults (4, 64)")
    func explicitAffineModeUsesDefaults() {
        var overrides = ServerCacheConfig()
        overrides.kvQuantMode = .affine
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: overrides
        )
        if case .affine(let bits, let groupSize) = params.kvMode {
            #expect(bits == 4, "affine bits default should be 4")
            #expect(groupSize == 64, "affine groupSize default should be 64")
        } else {
            Issue.record("expected .affine with defaults")
        }
    }

    @Test("prefillStepSize nil → 512 package default")
    func prefillStepSizeDefault() {
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: ServerCacheConfig()
        )
        #expect(params.prefillStepSize == 512, "nil prefillStepSize should produce the package default")
    }

    @Test("prefillStepSize set → forwarded to GenerateParameters")
    func prefillStepSizeForwarded() {
        var overrides = ServerCacheConfig()
        overrides.prefillStepSize = 1024
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: overrides
        )
        #expect(params.prefillStepSize == 1024, "custom prefillStepSize should flow through")
    }

    @Test("quantizedKVStart nil → 0 default")
    func quantizedKVStartDefault() {
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: ServerCacheConfig()
        )
        #expect(params.quantizedKVStart == 0, "nil quantizedKVStart should default to 0")
    }

    @Test("quantizedKVStart set → forwarded")
    func quantizedKVStartForwarded() {
        var overrides = ServerCacheConfig()
        overrides.quantizedKVStart = 256
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: overrides
        )
        #expect(params.quantizedKVStart == 256, "custom quantizedKVStart should flow through")
    }

    // MARK: - Defensive clamping (Hazard 2 from interaction audit)

    /// Hand-edited server.json can set values outside the UI range.
    /// `makeGenerateParameters` should clamp rather than forward
    /// potentially crash-worthy values into vmlx.

    @Test("turboKeyBits=99 (hand-edit) clamps to 8 (range max)")
    func turboKeyBitsClampedHigh() {
        var overrides = ServerCacheConfig()
        overrides.kvQuantMode = .turboQuant
        overrides.turboKeyBits = 99
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7, maxTokens: 256, topP: 1.0,
            repetitionPenalty: nil, maxKV: nil, cacheOverrides: overrides
        )
        if case .turboQuant(let keyBits, _) = params.kvMode {
            #expect(keyBits == 8, "key bits above 8 should clamp to 8, not forward 99")
        } else {
            Issue.record("expected .turboQuant")
        }
    }

    @Test("turboValueBits=0 clamps to 2 (range min)")
    func turboValueBitsClampedLow() {
        var overrides = ServerCacheConfig()
        overrides.kvQuantMode = .turboQuant
        overrides.turboValueBits = 0
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7, maxTokens: 256, topP: 1.0,
            repetitionPenalty: nil, maxKV: nil, cacheOverrides: overrides
        )
        if case .turboQuant(_, let valueBits) = params.kvMode {
            #expect(valueBits == 2, "value bits below 2 should clamp to 2, not forward 0")
        } else {
            Issue.record("expected .turboQuant")
        }
    }

    @Test("affineKVBits=16 clamps to 8")
    func affineKVBitsClamped() {
        var overrides = ServerCacheConfig()
        overrides.kvQuantMode = .affine
        overrides.affineKVBits = 16
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7, maxTokens: 256, topP: 1.0,
            repetitionPenalty: nil, maxKV: nil, cacheOverrides: overrides
        )
        if case .affine(let bits, _) = params.kvMode {
            #expect(bits == 8, "affine bits should clamp to 8")
        } else {
            Issue.record("expected .affine")
        }
    }

    @Test("prefillStepSize=-500 clamps to 64 (range min)")
    func prefillStepSizeClamped() {
        var overrides = ServerCacheConfig()
        overrides.prefillStepSize = -500
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7, maxTokens: 256, topP: 1.0,
            repetitionPenalty: nil, maxKV: nil, cacheOverrides: overrides
        )
        #expect(params.prefillStepSize == 64, "negative prefillStepSize should clamp to 64")
    }

    @Test("prefillStepSize=999999 clamps to 4096 (range max)")
    func prefillStepSizeClampedHigh() {
        var overrides = ServerCacheConfig()
        overrides.prefillStepSize = 999_999
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7, maxTokens: 256, topP: 1.0,
            repetitionPenalty: nil, maxKV: nil, cacheOverrides: overrides
        )
        #expect(params.prefillStepSize == 4096, "huge prefillStepSize should clamp to 4096")
    }
}

// MARK: - ServerConfiguration decoder isolation (Hazard 1)

@Suite("ServerConfiguration decoder isolation")
struct ServerConfigurationDecoderIsolationTests {

    /// Hazard 1: a typo in `cacheConfig` should NOT take down the entire
    /// ServerConfiguration decode. User still keeps port, hotkey, CORS, etc.

    @Test("Typo in cacheConfig.kvQuantMode falls back to cache default, rest is preserved")
    func cacheConfigTypoDoesNotBrickServerConfig() throws {
        // Note the invalid "TurboQuant" (capital T) — CacheQuantMode's raw
        // value is the lowercase "turboQuant", so this would throw.
        let json = """
        {
            "port": 4242,
            "exposeToNetwork": true,
            "startAtLogin": false,
            "hideDockIcon": false,
            "appearanceMode": "dark",
            "numberOfThreads": 8,
            "backlog": 256,
            "genTopP": 0.95,
            "allowedOrigins": ["https://foo.example.com"],
            "modelEvictionPolicy": "Strict (One Model)",
            "cacheConfig": {
                "kvQuantMode": "TurboQuant"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: data)
        // Port, CORS, and appearance should all be preserved from the JSON
        #expect(decoded.port == 4242)
        #expect(decoded.exposeToNetwork == true)
        #expect(decoded.genTopP == 0.95)
        #expect(decoded.allowedOrigins == ["https://foo.example.com"])
        #expect(decoded.appearanceMode == .dark)
        // cacheConfig falls back to defaults (isFullyAuto) because the
        // decoder isolation caught the typo
        #expect(decoded.cacheConfig.isFullyAuto)
    }

    @Test("Valid cacheConfig still decodes correctly alongside the isolation")
    func validCacheConfigStillDecodes() throws {
        let json = """
        {
            "port": 1337,
            "exposeToNetwork": false,
            "startAtLogin": false,
            "hideDockIcon": false,
            "appearanceMode": "system",
            "numberOfThreads": 8,
            "backlog": 256,
            "genTopP": 1.0,
            "allowedOrigins": [],
            "modelEvictionPolicy": "Strict (One Model)",
            "cacheConfig": {
                "kvQuantMode": "turboQuant",
                "turboKeyBits": 4
            }
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: data)
        #expect(decoded.cacheConfig.kvQuantMode == .turboQuant)
        #expect(decoded.cacheConfig.turboKeyBits == 4)
    }
}

// MARK: - AgentManager.effectiveMemoryEnabled precedence (Phase B M-05)

@Suite("AgentManager.effectiveMemoryEnabled precedence")
@MainActor
struct EffectiveMemoryEnabledTests {

    /// The default agent (built-in) is hard-coded to always follow the
    /// global setting, regardless of any attempted per-agent override.
    /// This keeps its semantics consistent with every other
    /// `effective*` resolver on AgentManager.

    @Test("default agent follows global (unknown or present)")
    func defaultAgentFollowsGlobal() {
        let global = MemoryConfigurationStore.load().enabled
        let effective = AgentManager.shared.effectiveMemoryEnabled(for: Agent.defaultId)
        #expect(effective == global, "default agent should mirror the global memory setting")
    }

    /// An unknown UUID should fall back to the global setting, NOT silently
    /// return false. Regression guard — the fallback branch was flagged
    /// during the Phase B audit as a place where a bad default could
    /// silently disable memory for malformed requests.

    @Test("unknown UUID falls back to global")
    func unknownAgentFallsBackToGlobal() {
        let global = MemoryConfigurationStore.load().enabled
        let unknownId = UUID()
        let effective = AgentManager.shared.effectiveMemoryEnabled(for: unknownId)
        #expect(effective == global, "unknown agent should fall back to global, not silent false")
    }
}
