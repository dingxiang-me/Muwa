//
//  MigrationCompatTests.swift
//  osaurusTests
//
//  Proves that configuration JSON files written before the
//  `feat/memory-tools-defaults` branch decode cleanly against the
//  new models and produce the expected post-flip defaults.
//
//  Covers:
//  - ChatConfiguration — disableTools flip (false → true),
//    showChatBarToolsChip new field, cacheConfig absence.
//  - MemoryConfiguration — enabled flip (true → false).
//  - ServerConfiguration — new cacheConfig field defaults to .default
//    (all nil = fully auto-tune, TurboQuant substituted at runtime).
//  - Agent — new memoryEnabled field decodes as nil for pre-branch files.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Configuration migration compat")
struct MigrationCompatTests {

    // MARK: - ChatConfiguration

    @Test("Pre-branch chat.json without disableTools key → decodes as true (Phase D flip)")
    func chatConfigMissingDisableToolsDecodesAsTrue() throws {
        // A chat.json file written before the Phase D flip never had the
        // `disableTools` key. The decoder fallback should return `true`
        // to match the new init default. Users who explicitly set
        // `"disableTools": false` must see their choice preserved (that's
        // covered by the explicit-false test below).
        let json = """
        {
            "systemPrompt": "",
            "maxTokens": 16384,
            "contextLength": 128000,
            "maxToolAttempts": 15
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        #expect(decoded.disableTools == true, "missing key should fall back to Phase D default of true")
    }

    @Test("Pre-branch chat.json with explicit disableTools=false → preserved")
    func chatConfigExplicitDisableToolsFalsePreserved() throws {
        let json = """
        {
            "systemPrompt": "",
            "maxTokens": 16384,
            "contextLength": 128000,
            "maxToolAttempts": 15,
            "disableTools": false
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        #expect(decoded.disableTools == false, "explicit false should not be clobbered by the flip")
    }

    @Test("Pre-branch chat.json without showChatBarToolsChip → decodes as true (default)")
    func chatConfigMissingShowChatBarToolsChipDecodesAsTrue() throws {
        // Phase E.2 added `showChatBarToolsChip` with a default of `true`.
        // Files written before E.2 landed don't have the key.
        let json = """
        {
            "systemPrompt": "",
            "maxTokens": 16384,
            "contextLength": 128000,
            "maxToolAttempts": 15
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        #expect(decoded.showChatBarToolsChip == true, "missing key should fall back to the Phase E.2 default of true")
    }

    // MARK: - MemoryConfiguration

    @Test("Pre-branch memory.json without enabled key → decodes as false (Phase D flip)")
    func memoryConfigMissingEnabledDecodesAsFalse() throws {
        // Phase D flipped MemoryConfiguration.enabled's init default from
        // true to false. The decoder fallback reads from
        // `MemoryConfiguration()` defaults, so this cascades automatically.
        let json = """
        {
            "embeddingBackend": "mlx",
            "embeddingModel": "nomic-embed-text-v1.5",
            "summaryRetentionDays": 180
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MemoryConfiguration.self, from: data)
        #expect(decoded.enabled == false, "missing key should fall back to Phase D default of false")
    }

    @Test("Pre-branch memory.json with explicit enabled=true → preserved")
    func memoryConfigExplicitEnabledTruePreserved() throws {
        let json = """
        {
            "embeddingBackend": "mlx",
            "embeddingModel": "nomic-embed-text-v1.5",
            "summaryRetentionDays": 180,
            "enabled": true
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MemoryConfiguration.self, from: data)
        #expect(decoded.enabled == true, "explicit true should not be clobbered by the flip")
    }

    // MARK: - ServerConfiguration (Phase E.1 + E.3)

    @Test("Pre-branch server.json without cacheConfig → decodes as .default (fully auto)")
    func serverConfigMissingCacheConfigDecodesAsDefault() throws {
        // Phase E.1 added `cacheConfig: ServerCacheConfig` to
        // ServerConfiguration. Files written before E.1 don't have the key;
        // the decoder should substitute `.default` (all fields nil).
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
            "modelEvictionPolicy": "Strict (One Model)"
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: data)
        #expect(decoded.cacheConfig.isFullyAuto, "missing cacheConfig should decode as ServerCacheConfig.default (every field nil)")
    }

    @Test("ServerCacheConfig with all fields nil reports isFullyAuto")
    func serverCacheConfigIsFullyAutoWhenEmpty() throws {
        let config = ServerCacheConfig()
        #expect(config.isFullyAuto, "default ServerCacheConfig should be fully auto")
    }

    @Test("ServerCacheConfig with any field set reports !isFullyAuto")
    func serverCacheConfigNotFullyAutoWhenAnyFieldSet() throws {
        // Each field gets its own case — they all need to break the fully-auto check.
        var config = ServerCacheConfig()
        config.prefillStepSize = 256
        #expect(!config.isFullyAuto)

        config = ServerCacheConfig()
        config.maxCacheBlocks = 1500
        #expect(!config.isFullyAuto)

        config = ServerCacheConfig()
        config.kvQuantMode = .turboQuant
        #expect(!config.isFullyAuto)

        config = ServerCacheConfig()
        config.ssmMaxEntries = 100
        #expect(!config.isFullyAuto)
    }

    @Test("ServerCacheConfig survives JSON round-trip")
    func serverCacheConfigRoundTrip() throws {
        let original = ServerCacheConfig(
            prefillStepSize: 1024,
            maxCacheBlocks: 1500,
            pagedBlockSize: 128,
            enableDiskCache: true,
            diskCacheMaxGB: 8.0,
            kvQuantMode: .turboQuant,
            turboKeyBits: 4,
            turboValueBits: 4
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(ServerCacheConfig.self, from: data)
        #expect(decoded == original, "round-trip should preserve every field")
    }

    @Test("CacheQuantMode enum cases round-trip via JSON")
    func cacheQuantModeRoundTrip() throws {
        let modes: [CacheQuantMode] = [.none, .affine, .turboQuant]
        for mode in modes {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(CacheQuantMode.self, from: data)
            #expect(decoded == mode, "mode \(mode) should round-trip")
        }
    }

    // MARK: - Agent (Phase B)

    @Test("Pre-branch agent.json without memoryEnabled → decodes as nil")
    func agentMissingMemoryEnabledDecodesAsNil() throws {
        // Phase B added `memoryEnabled: Bool?`. Pre-B agent files don't
        // have the key; the custom decoder uses decodeIfPresent which
        // returns nil for missing keys.
        let json = """
        {
            "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "name": "Research Assistant",
            "description": "A helpful research agent",
            "systemPrompt": "You are a research assistant.",
            "isBuiltIn": false,
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-15T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = json.data(using: .utf8)!
        let decoded = try decoder.decode(Agent.self, from: data)
        #expect(decoded.memoryEnabled == nil, "missing key should decode as nil (follow global)")
    }

    @Test("Agent with explicit memoryEnabled=true preserved")
    func agentExplicitMemoryEnabledTruePreserved() throws {
        let json = """
        {
            "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "name": "Research Assistant",
            "description": "",
            "systemPrompt": "",
            "isBuiltIn": false,
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-15T00:00:00Z",
            "memoryEnabled": true
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = json.data(using: .utf8)!
        let decoded = try decoder.decode(Agent.self, from: data)
        #expect(decoded.memoryEnabled == true, "explicit true should survive round-trip")
    }

    @Test("AgentMemoryOverride round-trip through Bool?")
    func agentMemoryOverrideRoundTrip() throws {
        // The UI picker uses AgentMemoryOverride; the model stores Bool?.
        // Prove the two conversions are inverses.
        for original in AgentMemoryOverride.allCases {
            let asBool = original.optionalBool
            let restored = AgentMemoryOverride.from(asBool)
            #expect(restored == original, "round-trip should preserve \(original)")
        }
    }
}
