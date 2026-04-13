//
//  ServerConfiguration.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation

/// KV cache quantization mode — shadow of `MLXLMCommon.KVQuantizationMode`
/// that's Codable-friendly. The associated-value cases in the package
/// enum aren't Codable out of the box, so osaurus stores the mode as a
/// string and the quant bits as separate fields. `ModelRuntime` rebuilds
/// the package enum from these fields on request.
public enum CacheQuantMode: String, Codable, Sendable, CaseIterable {
    case none
    case affine
    case turboQuant
}

/// User-facing overrides for the vmlx-swift-lm cache engine.
///
/// The KV caching system in osaurus is a **6-stack engine**, all of
/// which are now user-tunable from this struct:
///   1. **Continuous batching** (BatchEngine prefill) — `prefillStepSize`
///      (per-request, flows through `GenerateParameters`)
///   2. **Prefix caching** (PagedCacheManager L1) — `usePagedCache`,
///      `maxCacheBlocks`
///   3. **Paged blocks** (PagedCacheManager block pool) — `pagedBlockSize`
///      (shares budget with stack 2 via `maxCacheBlocks`)
///   4. **L2 disk cache** (DiskCache) — `enableDiskCache`, `diskCacheMaxGB`
///   5. **KV cache quantization** (affine or TurboQuant) — `kvQuantMode`,
///      `affineKVBits`, `affineKVGroupSize`, `turboKeyBits`, `turboValueBits`,
///      `quantizedKVStart` (per-request, flows through `GenerateParameters`)
///   6. **Hybrid SSM handler/watcher** (SSMStateCache) — `ssmMaxEntries`
///
/// **Stacks 2, 3, 4, 6** are `CacheCoordinatorConfig` fields and require
/// a **model reload** to take effect (coordinator is immutable).
///
/// **Stacks 1 and 5** flow through `GenerateParameters` on every request
/// and take effect on the **next generation** — no reload needed.
///
/// **Every field is optional.** `nil` means "let vmlx-swift-lm auto-tune
/// based on available RAM and model characteristics" — the historic
/// osaurus default. Users who never touch Settings → Cache get the same
/// behavior they had before this struct existed.
public struct ServerCacheConfig: Codable, Equatable, Sendable {

    // MARK: - Stack 1: Continuous batching

    /// Number of tokens per prefill chunk during prompt processing.
    /// Smaller = lower peak memory during prefill (helps on 8GB
    /// machines) at the cost of slightly slower prefill. Larger =
    /// faster prefill on high-memory machines. Per-request via
    /// `GenerateParameters.prefillStepSize`.
    /// `nil` = package default (512).
    public var prefillStepSize: Int?

    // MARK: - Stack 2+3: Prefix caching / paged blocks

    /// Whether to enable the paged L1 cache at all. Disabling is rarely
    /// useful — prefix caching is the main TTFT win — but exposed for
    /// A/B comparisons on ephemeral workloads.
    /// `nil` = package default (`true`).
    public var usePagedCache: Bool?

    /// Max block pool size (prefix cache capacity in blocks). Scale with
    /// RAM: more blocks = more prompts fit in cache.
    /// `nil` = auto-scaled to RAM (500 / 1000 / 2000 for <16GB / 16-48GB / >48GB).
    public var maxCacheBlocks: Int?

    /// Tokens per paged block. Smaller blocks = finer-grained reuse but
    /// more metadata overhead; larger blocks = coarser reuse.
    /// Valid: 32, 64, 128. `nil` = package default (64).
    public var pagedBlockSize: Int?

    // MARK: - Stack 4: L2 disk cache

    /// Whether to enable the disk KV cache tier. `nil` = auto-enabled
    /// when the disk cache directory is writable. Explicit `false`
    /// forces memory-only (useful for SSD-conscious setups).
    public var enableDiskCache: Bool?

    /// Max disk cache size in GB. `nil` = 4.0 GB. Users with small SSDs
    /// can lower this; users who churn long contexts can raise it.
    /// Type is `Float` to match `CacheCoordinatorConfig.diskCacheMaxGB`.
    public var diskCacheMaxGB: Float?

    // MARK: - Stack 5: KV cache quantization

    /// Quantization mode for the KV cache during generation. Per-request
    /// via `GenerateParameters.kvMode`.
    /// - `.none` (or nil) — no quantization, full-precision KV cache
    /// - `.affine` — legacy affine quantization, tunable via
    ///   `affineKVBits` + `affineKVGroupSize`
    /// - `.turboQuant` — TurboQuant (the vmlx-native scheme), tunable
    ///   via `turboKeyBits` + `turboValueBits`
    public var kvQuantMode: CacheQuantMode?

    /// Bits per element for affine quantization. Common values: 2, 4, 8.
    /// Only used when `kvQuantMode == .affine`. `nil` = package default.
    public var affineKVBits: Int?

    /// Group size for affine quantization. Only used when
    /// `kvQuantMode == .affine`. `nil` = package default (64).
    public var affineKVGroupSize: Int?

    /// Key-side bits per element for TurboQuant. Only used when
    /// `kvQuantMode == .turboQuant`. `nil` = package default (3).
    public var turboKeyBits: Int?

    /// Value-side bits per element for TurboQuant. Only used when
    /// `kvQuantMode == .turboQuant`. `nil` = package default (3).
    public var turboValueBits: Int?

    /// Token count threshold at which quantization begins. Tokens before
    /// this offset stay full-precision regardless of mode. Useful for
    /// preserving short prompts while quantizing long contexts.
    /// `nil` = package default (0 — quantize immediately).
    public var quantizedKVStart: Int?

    // MARK: - Stack 6: Hybrid SSM handler

    /// Max entries in the SSM companion cache for hybrid models (models
    /// with state-space layers like Mamba). Only effective when osaurus
    /// auto-detects a hybrid model at load time. `nil` = package default (50).
    public var ssmMaxEntries: Int?

    public init(
        prefillStepSize: Int? = nil,
        usePagedCache: Bool? = nil,
        maxCacheBlocks: Int? = nil,
        pagedBlockSize: Int? = nil,
        enableDiskCache: Bool? = nil,
        diskCacheMaxGB: Float? = nil,
        kvQuantMode: CacheQuantMode? = nil,
        affineKVBits: Int? = nil,
        affineKVGroupSize: Int? = nil,
        turboKeyBits: Int? = nil,
        turboValueBits: Int? = nil,
        quantizedKVStart: Int? = nil,
        ssmMaxEntries: Int? = nil
    ) {
        self.prefillStepSize = prefillStepSize
        self.usePagedCache = usePagedCache
        self.maxCacheBlocks = maxCacheBlocks
        self.pagedBlockSize = pagedBlockSize
        self.enableDiskCache = enableDiskCache
        self.diskCacheMaxGB = diskCacheMaxGB
        self.kvQuantMode = kvQuantMode
        self.affineKVBits = affineKVBits
        self.affineKVGroupSize = affineKVGroupSize
        self.turboKeyBits = turboKeyBits
        self.turboValueBits = turboValueBits
        self.quantizedKVStart = quantizedKVStart
        self.ssmMaxEntries = ssmMaxEntries
    }

    public static let `default` = ServerCacheConfig()

    /// True when every field is nil (pure auto-tune mode). UI uses this
    /// to show an "Auto" badge instead of a mixed state.
    public var isFullyAuto: Bool {
        prefillStepSize == nil
            && usePagedCache == nil && maxCacheBlocks == nil
            && pagedBlockSize == nil && enableDiskCache == nil
            && diskCacheMaxGB == nil
            && kvQuantMode == nil && affineKVBits == nil
            && affineKVGroupSize == nil && turboKeyBits == nil
            && turboValueBits == nil && quantizedKVStart == nil
            && ssmMaxEntries == nil
    }
}

/// Appearance mode setting for the app
public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Configuration settings for the server
public struct ServerConfiguration: Codable, Equatable, Sendable {
    /// Server port (1-65535)
    public var port: Int

    /// Expose the server to the local network (0.0.0.0) or keep it on localhost (127.0.0.1)
    public var exposeToNetwork: Bool

    /// Start Osaurus automatically at login
    public var startAtLogin: Bool

    /// Hide the dock icon (run as accessory app)
    public var hideDockIcon: Bool

    /// Appearance mode (system, light, or dark)
    public var appearanceMode: AppearanceMode

    /// Number of threads for the event loop group
    public let numberOfThreads: Int

    /// Server backlog size
    public let backlog: Int32

    // MARK: - Generation Settings (UI adjustable)
    /// Default top-p sampling for generation (can be overridden per request)
    public var genTopP: Float
    /// Maximum KV cache size (tokens); nil for unlimited
    public var genMaxKVSize: Int?

    // KV cache quantization (kvBits, kvGroupSize, quantizedKVStart, turboQuant)
    // remains owned by the vmlx-swift-lm package — quant bits are baked
    // into model weights and have no per-session override mechanism. The
    // other 5 stacks of the cache engine are now user-configurable via
    // `cacheConfig` below, with every field defaulting to nil so existing
    // users see zero behavior change until they explicitly tune.

    /// User-facing overrides for the vmlx-swift-lm cache engine. See
    /// `ServerCacheConfig` docs for the 6-stack breakdown. Every field is
    /// optional; `nil` means "auto-tune per RAM + model".
    public var cacheConfig: ServerCacheConfig

    /// List of allowed origins for CORS. Empty disables CORS. Use "*" to allow any origin.
    public var allowedOrigins: [String]

    /// Memory management policy for loaded models
    public var modelEvictionPolicy: ModelEvictionPolicy

    private enum CodingKeys: String, CodingKey {
        case port
        case exposeToNetwork
        case startAtLogin
        case hideDockIcon
        case appearanceMode
        case numberOfThreads
        case backlog
        case genTopP
        case genMaxKVSize
        case cacheConfig
        case allowedOrigins
        case modelEvictionPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerConfiguration.default
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        self.exposeToNetwork =
            try container.decodeIfPresent(Bool.self, forKey: .exposeToNetwork) ?? defaults.exposeToNetwork
        self.startAtLogin =
            try container.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? defaults.startAtLogin
        self.hideDockIcon =
            try container.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? defaults.hideDockIcon
        self.appearanceMode =
            try container.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode) ?? defaults.appearanceMode
        self.numberOfThreads =
            try container.decodeIfPresent(Int.self, forKey: .numberOfThreads) ?? defaults.numberOfThreads
        self.backlog = try container.decodeIfPresent(Int32.self, forKey: .backlog) ?? defaults.backlog
        self.genTopP = try container.decodeIfPresent(Float.self, forKey: .genTopP) ?? defaults.genTopP
        self.genMaxKVSize = try container.decodeIfPresent(Int.self, forKey: .genMaxKVSize)
        // Decoder isolation: a typo in hand-edited `cacheConfig` JSON
        // (e.g. `"kvQuantMode": "TurboQuant"` with wrong case) would
        // otherwise throw and take the entire ServerConfiguration decode
        // down with it — losing port, hotkey, allowedOrigins, eviction
        // policy, all of it back to defaults. Catch the cacheConfig error
        // specifically, log it, and fall back to the default cache config.
        // User keeps the rest of their server settings. See
        // `07-DEFERRED-FIXES.md` hazard audit and `08-INTERACTION-AUDIT.md`.
        do {
            self.cacheConfig =
                try container.decodeIfPresent(ServerCacheConfig.self, forKey: .cacheConfig) ?? defaults.cacheConfig
        } catch {
            print("[Osaurus] ServerConfiguration.cacheConfig decode failed, falling back to defaults: \(error)")
            self.cacheConfig = defaults.cacheConfig
        }
        self.allowedOrigins =
            try container.decodeIfPresent([String].self, forKey: .allowedOrigins)
            ?? defaults.allowedOrigins
        self.modelEvictionPolicy =
            try container.decodeIfPresent(ModelEvictionPolicy.self, forKey: .modelEvictionPolicy)
            ?? defaults.modelEvictionPolicy
    }

    public init(
        port: Int,
        exposeToNetwork: Bool,
        startAtLogin: Bool,
        hideDockIcon: Bool = false,
        appearanceMode: AppearanceMode = .system,
        numberOfThreads: Int,
        backlog: Int32,
        genTopP: Float,
        genMaxKVSize: Int?,
        cacheConfig: ServerCacheConfig = .default,
        allowedOrigins: [String] = [],
        modelEvictionPolicy: ModelEvictionPolicy = .strictSingleModel
    ) {
        self.port = port
        self.exposeToNetwork = exposeToNetwork
        self.startAtLogin = startAtLogin
        self.hideDockIcon = hideDockIcon
        self.appearanceMode = appearanceMode
        self.numberOfThreads = numberOfThreads
        self.backlog = backlog
        self.genTopP = genTopP
        self.genMaxKVSize = genMaxKVSize
        self.cacheConfig = cacheConfig
        self.allowedOrigins = allowedOrigins
        self.modelEvictionPolicy = modelEvictionPolicy
    }

    /// Default configuration
    public static var `default`: ServerConfiguration {
        ServerConfiguration(
            port: 1337,
            exposeToNetwork: false,
            startAtLogin: false,
            hideDockIcon: false,
            appearanceMode: .system,
            numberOfThreads: ProcessInfo.processInfo.activeProcessorCount,
            backlog: 256,
            genTopP: 1.0,
            genMaxKVSize: nil,
            cacheConfig: .default,
            allowedOrigins: [],
            modelEvictionPolicy: .strictSingleModel
        )
    }

    /// Validates if the port is in valid range
    public var isValidPort: Bool {
        (1 ..< 65536).contains(port)
    }
}

/// Policy for managing model eviction from memory
public enum ModelEvictionPolicy: String, Codable, CaseIterable, Sendable {
    /// Strictly keep only one model loaded at a time (safest for memory)
    case strictSingleModel = "Strict (One Model)"
    /// Allow multiple models (best for high RAM systems or rapid switching)
    case manualMultiModel = "Flexible (Multi Model)"

    public var description: String {
        switch self {
        case .strictSingleModel:
            return "Automatically unloads other models. Recommended for standard use."
        case .manualMultiModel:
            return "Keeps models loaded until manually unloaded. Requires 32GB+ RAM."
        }
    }
}
