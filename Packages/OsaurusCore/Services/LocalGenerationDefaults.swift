//
//  LocalGenerationDefaults.swift
//  osaurus
//
//  Reads sampling defaults from a locally-installed model bundle and
//  surfaces them (temperature / top_p / top_k / repetition_penalty) so
//  osaurus can honor them when the OpenAI-wire request omits the
//  corresponding field.
//
//  Two sources are consulted, in priority order:
//
//    1. `jang_config.json > chat > sampling_defaults` — present on JANG /
//       JANGTQ bundles that ship the newer chat-metadata schema (DSV4,
//       Kimi K2.6, newer Gemma-4 / Qwen-3.6 JANG snapshots). These are
//       authoritative for JANG converters — the DSV4 `convert_dsv4_jangtq.py`
//       reads `inference/generate.py` defaults directly and stamps them
//       here, which may differ from the source model's generic
//       `generation_config.json` (e.g. DSV4 uses temp=0.6, while the
//       upstream HF config specifies temp=1.0).
//
//    2. `generation_config.json` — Hugging Face's standard sampling-default
//       file, present on every instruction-tuned checkpoint regardless of
//       quantization. vmlx's `GenerationConfigFile`
//       (Libraries/MLXLMCommon/GenerationConfigFile.swift) only decodes
//       `eos_token_id` from this file, so reading the sampling fields is
//       osaurus's job.
//
//  Ignoring these served, e.g., Qwen 3.5 397B-A17B at 0.7 temperature when
//  its training recipe specifies 0.6, Gemma-4 26B-A4B with top_k disabled
//  when the recipe specifies top_k=64, and (critically) DSV4-Flash-JANGTQ
//  with the upstream HF config's temp=1.0 rather than DeepSeek's tuned
//  temp=0.6 shipped in the JANG config.
//
//  JANG bundles that ship BOTH files get the JANG chat.sampling_defaults
//  applied first, with any fields the JANG config omits filled from
//  generation_config.json. Bundles that ship neither return `.empty` and
//  the caller's hardcoded fallback ladder takes over.
//

import Foundation

enum LocalGenerationDefaults {

    struct Defaults: Sendable, Equatable {
        var temperature: Float?
        var topP: Float?
        var topK: Int?
        var repetitionPenalty: Float?

        static let empty = Defaults()
    }

    private static nonisolated let lock = NSLock()
    private static nonisolated(unsafe) var cache: [String: Defaults] = [:]

    /// Resolve and cache the sampling defaults for `modelId`. The id may be
    /// either the short picker name or the full `ORG/REPO` identifier; both
    /// are supported via `ModelManager.findInstalledModel`.
    static func defaults(forModelId modelId: String) -> Defaults {
        let key = modelId.lowercased()
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let resolved = load(modelId: modelId)

        lock.lock()
        cache[key] = resolved
        lock.unlock()
        return resolved
    }

    /// Invalidate the cache. Call when models are added/removed so the next
    /// lookup re-reads the file from disk.
    static func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - File loading

    private static func load(modelId: String) -> Defaults {
        guard let dir = localDirectory(forModelId: modelId) else {
            return .empty
        }
        return load(fromDirectory: dir)
    }

    /// Read sampling defaults from an on-disk model directory. Checks both
    /// `jang_config.json` (authoritative when present) and
    /// `generation_config.json` (HF fallback), merging so that every field
    /// is filled from whichever file sets it first. Exposed so integration
    /// tests can exercise the full filesystem path without needing
    /// `ModelManager.findInstalledModel` to resolve a real install.
    /// Returns `.empty` if neither file is present or all parses fail.
    static func load(fromDirectory dir: URL) -> Defaults {
        let jang = loadJangConfigDefaults(at: dir)
        let hf = loadHuggingFaceGenerationDefaults(at: dir)
        return merge(primary: jang, fallback: hf)
    }

    private static func loadJangConfigDefaults(at dir: URL) -> Defaults {
        let url = dir.appendingPathComponent("jang_config.json")
        guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else {
            return .empty
        }
        return parseJangConfig(data: data)
    }

    private static func loadHuggingFaceGenerationDefaults(at dir: URL) -> Defaults {
        let url = dir.appendingPathComponent("generation_config.json")
        guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else {
            return .empty
        }
        return parse(data: data)
    }

    private static func localDirectory(forModelId modelId: String) -> URL? {
        guard let found = ModelManager.findInstalledModel(named: modelId) else {
            return nil
        }
        let parts = found.id.split(separator: "/").map(String.init)
        let base = DirectoryPickerService.effectiveModelsDirectory()
        return parts.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    // MARK: - Parsers

    /// Pure, testable JSON parse for HuggingFace `generation_config.json`.
    /// Extracted so unit tests can feed in bundled fixtures without touching
    /// the filesystem.
    static func parse(data: Data) -> Defaults {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        return extractSamplingFields(from: obj)
    }

    /// Pure, testable JSON parse for `jang_config.json`'s
    /// `chat.sampling_defaults` sub-object. The JANG schema (per
    /// `jang-tools/dsv4_prune/convert_dsv4_jangtq.py`) places sampling
    /// defaults at a dotted path — anything else at the top level
    /// (quantization, source_model, crack_surgery, etc.) is ignored by
    /// this function.
    static func parseJangConfig(data: Data) -> Defaults {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let chat = root["chat"] as? [String: Any],
            let sampling = chat["sampling_defaults"] as? [String: Any]
        else {
            return .empty
        }
        return extractSamplingFields(from: sampling)
    }

    /// Merge two `Defaults` values field-by-field, preferring `primary` for
    /// any field it sets. Used to overlay `jang_config.json` over
    /// `generation_config.json`.
    static func merge(primary: Defaults, fallback: Defaults) -> Defaults {
        var out = primary
        if out.temperature == nil { out.temperature = fallback.temperature }
        if out.topP == nil { out.topP = fallback.topP }
        if out.topK == nil { out.topK = fallback.topK }
        if out.repetitionPenalty == nil { out.repetitionPenalty = fallback.repetitionPenalty }
        return out
    }

    private static func extractSamplingFields(from obj: [String: Any]) -> Defaults {
        var out = Defaults()
        if let t = readFloat(obj["temperature"]) { out.temperature = t }
        if let p = readFloat(obj["top_p"]) { out.topP = p }
        if let k = readInt(obj["top_k"]) { out.topK = k }
        if let rp = readFloat(obj["repetition_penalty"]) { out.repetitionPenalty = rp }
        return out
    }

    /// JSON numbers land as `NSNumber` once bridged through `JSONSerialization`.
    /// Int/Double are interchangeable at the Obj-C layer but Swift's `as? Double`
    /// rejects `NSNumber` backed by an integer literal, so we funnel through
    /// the explicit helpers instead of a single conditional cast.
    private static func readFloat(_ any: Any?) -> Float? {
        if let n = any as? NSNumber { return n.floatValue }
        return nil
    }

    private static func readInt(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
