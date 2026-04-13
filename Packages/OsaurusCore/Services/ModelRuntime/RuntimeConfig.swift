//
//  RuntimeConfig.swift
//  osaurus
//
//  Captures a snapshot of server-side generation configuration used by MLX.
//  KV cache quantization, TurboQuant, and prefill step sizing flow through
//  `cacheOverrides` and take effect on the next generation — see
//  `ServerCacheConfig` for the 6-stack breakdown.
//

import Foundation

struct RuntimeConfig: Sendable {
    let topP: Float
    let maxKV: Int?
    /// Per-request cache engine overrides. Fields are all optional; nil
    /// means "auto-tune". `ModelRuntime.makeGenerateParameters` substitutes
    /// osaurus's preferred defaults (e.g. TurboQuant for `kvQuantMode`)
    /// when these are nil. See `ServerCacheConfig` docs.
    let cacheOverrides: ServerCacheConfig

    /// Captures a generation config snapshot from ServerConfiguration.
    static func snapshot() async -> RuntimeConfig {
        let cfg = await ServerController.sharedConfiguration()
        return RuntimeConfig(
            topP: cfg?.genTopP ?? 1.0,
            maxKV: cfg?.genMaxKVSize ?? Self.defaultMaxKV(),
            cacheOverrides: cfg?.cacheConfig ?? .default
        )
    }

    /// Auto-detect a reasonable maxKV default based on available system RAM.
    /// Machines with more RAM can afford larger context windows.
    private static func defaultMaxKV() -> Int {
        let ramGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        switch ramGB {
        case 0 ..< 24: return 8192
        case 24 ..< 48: return 16384
        case 48 ..< 96: return 32768
        default: return 65536
        }
    }
}
