//
//  TTSService.swift
//  osaurus
//
//  PocketTTS (FluidAudio) text-to-speech service. Streams 80 ms audio frames
//  from the model into an AVAudioEngine player node for real-time playback.
//

import AVFoundation
import Combine
@preconcurrency import FluidAudio
import Foundation

/// Errors mapped onto tool error envelopes by the `speak` tool.
public enum TTSPlaybackError: Error {
    case modelNotReady
}

/// Model-readiness state for PocketTTS.
public enum TTSModelState: Equatable {
    case notReady
    /// `fraction` is in [0, 1]. `nil` means indeterminate (e.g. compile phase).
    case downloading(fraction: Double?)
    case ready
    case failed(String)
}

/// Singleton that owns the PocketTTS manager, audio engine, and playback lifecycle.
@MainActor
public final class TTSService: ObservableObject {
    public static let shared = TTSService()

    // MARK: - Published state

    /// ID of the message currently being spoken. `nil` when idle.
    @Published public private(set) var playingMessageId: UUID? {
        didSet {
            if oldValue != playingMessageId {
                // Clear the tool-call binding when playback ends so
                // the row's spinner stops alongside the audio.
                if playingMessageId == nil { activeSpeakCallId = nil }
                NotificationCenter.default.post(name: .ttsPlaybackStateChanged, object: nil)
            }
        }
    }

    /// Tracks whether the PocketTTS model is initialized and usable.
    @Published public private(set) var modelState: TTSModelState = .notReady

    /// Tool-call id driving the current playback (`nil` for the manual
    /// speaker button or when idle). The inline tool card watches this
    /// to swap its check for a spinner while audio is still playing.
    @Published public private(set) var activeSpeakCallId: String? {
        didSet {
            if oldValue != activeSpeakCallId {
                NotificationCenter.default.post(name: .ttsPlaybackStateChanged, object: nil)
            }
        }
    }

    // MARK: - Private state

    private var manager: PocketTtsManager?
    private var playbackTask: Task<Void, Never>?
    private var initTask: Task<Void, Never>?
    /// Language pack the in-memory `manager` was built for. PocketTtsManager
    /// is bound to one language for its lifetime, so a language change tears
    /// the manager down and rebuilds it (see `languageDidChange`).
    private var loadedLanguage: PocketTtsLanguage?

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let sourceFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
    }()
    private var engineConfigured = false
    private var pendingBufferCount = 0
    private var streamFinished = false

    private init() {}

    // MARK: - Public API

    /// True when the model is fully loaded and ready to synthesize.
    public var isModelReady: Bool {
        if case .ready = modelState { return true }
        return false
    }

    /// Toggle speech for a given message. Tapping the currently-playing
    /// message stops playback; tapping a different message switches to it.
    /// If the model isn't downloaded yet, posts `.openTTSSettingsRequested`.
    public func toggleSpeak(text: String, messageId: UUID, voiceOverride: String? = nil) {
        if playingMessageId == messageId {
            stop()
            return
        }

        guard isModelReady else {
            if Self.pocketTtsModelsExistOnDisk(for: Self.currentLanguage()) {
                // Models already downloaded; just load them into memory.
                ensureModelLoaded()
            } else {
                NotificationCenter.default.post(name: .openTTSSettingsRequested, object: nil)
            }
            return
        }

        let plain = MarkdownStripper.plainText(from: text)
        guard !plain.isEmpty else { return }

        stop()
        playingMessageId = messageId
        startPlayback(text: plain, messageId: messageId, voiceOverride: voiceOverride)
    }

    /// Fire-and-forget playback for the `speak` tool. Sets
    /// `activeSpeakCallId` so the row spinner runs until audio drains
    public func startToolPlayback(text: String, messageId: UUID, callId: String, voiceOverride: String? = nil) throws {
        guard isModelReady else {
            if Self.pocketTtsModelsExistOnDisk(for: Self.currentLanguage()) {
                ensureModelLoaded()
            } else {
                NotificationCenter.default.post(name: .openTTSSettingsRequested, object: nil)
            }
            throw TTSPlaybackError.modelNotReady
        }
        let plain = MarkdownStripper.plainText(from: text)
        guard !plain.isEmpty else { return }

        stop()
        playingMessageId = messageId
        activeSpeakCallId = callId
        startPlayback(text: plain, messageId: messageId, voiceOverride: voiceOverride)
    }

    /// Stop any in-flight synthesis and clear playback state.
    public func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        streamFinished = true
        pendingBufferCount = 0
        if engineConfigured {
            playerNode.stop()
            playerNode.reset()
        }
        playingMessageId = nil
    }

    /// Begin a background download/initialize. Safe to call multiple times.
    public func ensureModelLoaded() {
        if case .ready = modelState { return }
        if initTask != nil { return }

        // Heal any English pack corrupted by the short-lived file-reuse
        // migration before we try to load it (see `resetCorruptedEnglishCacheIfNeeded`).
        Self.resetCorruptedEnglishCacheIfNeeded()

        modelState = .downloading(fraction: nil)
        let config = TTSConfigurationStore.load()
        let voice = config.voice
        let language = Self.resolvePocketLanguage(config)
        initTask = Task { [weak self] in
            do {
                // Route through the downloader explicitly so we get progress callbacks.
                // When models are already cached this returns nearly instantly.
                _ = try await PocketTtsResourceDownloader.ensureModels(
                    language: language,
                    directory: nil,
                    progressHandler: { progress in
                        Task { @MainActor in
                            guard let self else { return }
                            let fraction: Double?
                            switch progress.phase {
                            case .downloading:
                                fraction = progress.fractionCompleted
                            case .listing, .compiling:
                                fraction = nil
                            }
                            self.modelState = .downloading(fraction: fraction)
                        }
                    }
                )

                let mgr = PocketTtsManager(defaultVoice: voice, language: language)
                try await mgr.initialize()
                // A language switch may have cancelled us mid-flight; don't
                // install a manager for a language the user no longer wants.
                try Task.checkCancellation()
                // English now lives under `v2/english/`; drop the dead pre-v2
                // flat-layout files (~700 MB) that this version never reads.
                if language == .english { Self.cleanupLegacyFlatCache() }
                await MainActor.run {
                    guard let self else { return }
                    self.manager = mgr
                    self.loadedLanguage = language
                    self.modelState = .ready
                    self.initTask = nil
                    // Let views that auto-started a download replay the message
                    // the user originally asked for, now that the model loaded.
                    NotificationCenter.default.post(name: .ttsModelDidBecomeReady, object: nil)
                }
            } catch is CancellationError {
                await MainActor.run { self?.initTask = nil }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.modelState = .failed(error.localizedDescription)
                    self.initTask = nil
                }
            }
        }
    }

    /// Refresh `modelState` by checking the PocketTTS cache on disk.
    /// Call this on app launch and when returning to the settings tab.
    /// If models are already present, transitions to `.ready` after a fast local load.
    public func refreshModelState() {
        if case .ready = modelState { return }
        if initTask != nil { return }

        // Drop a corrupted English pack before the existence check below, so a
        // poisoned cache reports `.notReady` instead of loading into gibberish.
        Self.resetCorruptedEnglishCacheIfNeeded()

        if Self.pocketTtsModelsExistOnDisk(for: Self.currentLanguage()) {
            ensureModelLoaded()
        } else {
            modelState = .notReady
        }
    }

    /// Tear down the current manager and re-evaluate readiness when the user
    /// changes the language or quality tier. If the newly-selected pack is
    /// already cached it loads immediately; otherwise the state drops to
    /// `.notReady` so the settings tab prompts a download.
    public func languageDidChange() {
        let desired = Self.resolvePocketLanguage(TTSConfigurationStore.load())
        // Already on the requested pack and loaded — nothing to do.
        if loadedLanguage == desired, case .ready = modelState { return }

        stop()
        // Abandon any in-flight init bound to the old language. The init
        // task checks `Task.isCancelled` before installing its manager.
        initTask?.cancel()
        initTask = nil
        manager = nil
        loadedLanguage = nil
        modelState = .notReady
        refreshModelState()
    }

    /// The PocketTTS language pack implied by the persisted configuration.
    private static func currentLanguage() -> PocketTtsLanguage {
        resolvePocketLanguage(TTSConfigurationStore.load())
    }

    private static func pocketTtsModelsExistOnDisk(for language: PocketTtsLanguage) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Packs live under `pocket-tts/v2/<lang>/`. Mirror the library's own
        // `repoSubdirectory` so this check tracks wherever it downloads to.
        let languageRoot =
            home
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("fluidaudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("pocket-tts", isDirectory: true)
            .appendingPathComponent(language.repoSubdirectory, isDirectory: true)
        let required = ModelNames.PocketTTS.requiredModels
        let fm = FileManager.default
        return required.allSatisfy {
            fm.fileExists(atPath: languageRoot.appendingPathComponent($0).path)
        }
    }

    /// Resolve the persisted base-language + quality settings into a concrete
    /// FluidAudio language pack. English ships only a 6-layer pack and French
    /// only a 24-layer one, so the quality flag is honored only for the
    /// languages that publish both variants.
    private static func resolvePocketLanguage(_ config: TTSConfiguration) -> PocketTtsLanguage {
        let hq = config.highQuality
        switch config.language {
        case "french": return .french24L
        case "german": return hq ? .german24L : .german
        case "italian": return hq ? .italian24L : .italian
        case "portuguese": return hq ? .portuguese24L : .portuguese
        case "spanish": return hq ? .spanish24L : .spanish
        case "english": return .english
        default: return .english
        }
    }

    // MARK: - Cache layout / corruption healing

    /// Repo cache directory shared by all PocketTTS language packs
    /// (`~/.cache/fluidaudio/Models/pocket-tts/`).
    private static func pocketTtsRepoDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("fluidaudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("pocket-tts", isDirectory: true)
    }

    private static func englishLanguageRoot() -> URL {
        pocketTtsRepoDir().appendingPathComponent(
            PocketTtsLanguage.english.repoSubdirectory, isDirectory: true)
    }

    /// One-shot heal for caches damaged by the short-lived file-reuse
    /// migration. That build relocated the pre-v2 English CoreML models into
    /// `v2/english/` and downloaded only the delta — but those older models
    /// are incompatible with the v2 pre-baked voice snapshots and produced
    /// gibberish audio (loading succeeds, so nothing throws). We can't tell a
    /// poisoned `v2/english/` from a clean one by inspection, so we wipe it
    /// once and let the next load clean-download. Gated by a flag so a
    /// healthy pack is never deleted on subsequent launches.
    ///
    /// Only ever affects caches produced by that intermediate build: shipped
    /// users sit on the flat pre-v2 layout (no `v2/english/`), and clean
    /// installs download fresh after the flag is already set.
    private static let cacheHealFlagKey = "osaurus.tts.englishCacheHealV1"
    private static func resetCorruptedEnglishCacheIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: cacheHealFlagKey) else { return }
        defaults.set(true, forKey: cacheHealFlagKey)

        let langRoot = englishLanguageRoot()
        if FileManager.default.fileExists(atPath: langRoot.path) {
            do {
                try FileManager.default.removeItem(at: langRoot)
                print("[TTSService] Removed possibly-corrupted English pack for clean re-download")
            } catch {
                print("[TTSService] Failed to reset English pack: \(error)")
            }
        }
    }

    /// Delete the dead pre-v2 flat-layout English files once the model has
    /// loaded from `v2/english/`. This version never reads them, so they're
    /// ~700 MB of reclaimable disk for users upgrading from the old layout.
    /// Idempotent; safe to call on every successful English load.
    private static func cleanupLegacyFlatCache() {
        let repo = pocketTtsRepoDir()
        let fm = FileManager.default
        let leftovers = [
            ModelNames.PocketTTS.condStepFile,
            ModelNames.PocketTTS.flowlmStepFile,
            ModelNames.PocketTTS.flowDecoderFile,
            "mimi_decoder_v2.mlmodelc",
            ModelNames.PocketTTS.constantsBinDir,
            "config.json",
        ]
        for name in leftovers {
            let url = repo.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        }
    }

    /// Approximate download size for the inline download dialog's copy.
    public struct TTSDownloadPlan: Sendable {
        /// Human-readable approximate download size, or `nil` when unknown
        /// (24-layer packs vary and aren't quoted to avoid over-promising).
        public let sizeText: String?
    }

    /// Plan for the currently-configured language. Each language is a full,
    /// independent download — there is no partial/in-place upgrade path.
    public static func plannedDownload() -> TTSDownloadPlan {
        // 6-layer packs (incl. English) are ~770 MB; 24-layer packs are larger
        // and not quoted to avoid an inaccurate number.
        if currentLanguage().transformerLayers == 6 {
            return TTSDownloadPlan(sizeText: "about 770 MB")
        }
        return TTSDownloadPlan(sizeText: nil)
    }

    // MARK: - Playback

    private func startPlayback(text: String, messageId: UUID, voiceOverride: String? = nil) {
        do {
            try configureEngineIfNeeded()
        } catch {
            modelState = .failed(error.localizedDescription)
            playingMessageId = nil
            return
        }

        guard let manager else {
            playingMessageId = nil
            return
        }

        streamFinished = false
        pendingBufferCount = 0
        playerNode.play()

        let config = TTSConfigurationStore.load()
        let trimmedOverride = voiceOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = (trimmedOverride?.isEmpty == false ? trimmedOverride! : config.voice)
        let temperature = Float(config.temperature)

        playbackTask = Task { [weak self] in
            do {
                let stream = try await manager.synthesizeStreaming(
                    text: text,
                    voice: voice,
                    temperature: temperature
                )
                for try await frame in stream {
                    if Task.isCancelled { break }
                    self?.schedule(samples: frame.samples)
                }
                self?.markStreamFinished(for: messageId)
            } catch is CancellationError {
                // stop() already cleared state
            } catch {
                self?.handleStreamError(error, for: messageId)
            }
        }
    }

    private func schedule(samples: [Float]) {
        guard let buffer = makeBuffer(from: samples) else { return }
        pendingBufferCount += 1
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                self?.bufferDidFinish()
            }
        }
    }

    private func bufferDidFinish() {
        pendingBufferCount = max(0, pendingBufferCount - 1)
        if streamFinished, pendingBufferCount == 0 {
            playingMessageId = nil
            playerNode.stop()
        }
    }

    private func markStreamFinished(for messageId: UUID) {
        guard playingMessageId == messageId else { return }
        streamFinished = true
        if pendingBufferCount == 0 {
            playingMessageId = nil
            playerNode.stop()
        }
    }

    private func handleStreamError(_ error: Error, for messageId: UUID) {
        print("[TTSService] synthesis error: \(error)")
        if playingMessageId == messageId {
            stop()
        }
    }

    private func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let ptr = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                ptr.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    private func configureEngineIfNeeded() throws {
        if engineConfigured, audioEngine.isRunning { return }
        if !engineConfigured {
            audioEngine.attach(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: sourceFormat)
            engineConfigured = true
        }
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
    }
}

/// built-in PocketTTS voices (kyutai/pocket-tts on HuggingFace). shared by
/// the TTS settings tab and the per-agent voice picker.
public enum PocketTTSVoiceCatalog {
    /// 26 voice names shared across every language pack. The first 21 are the
    /// English-trained "literary" voices; the trailing 5 were recorded
    /// natively in their target language (see `PocketTTSLanguageCatalog`).
    /// The underlying acoustic embeddings are per-language, so any voice can
    /// be paired with any pack — the native ones just sound most idiomatic
    /// in their matching language.
    public static let availableVoices: [String] = [
        "alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles",
        "cosette", "eponine", "eve", "fantine", "george", "jane",
        "javert", "jean", "marius", "mary", "michael", "paul",
        "peter_yearsley", "stuart_bell", "vera",
        "estelle", "giovanni", "juergen", "lola", "rafael",
    ]

    public static func displayName(for voice: String) -> String {
        voice.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// PocketTTS language packs surfaced in the TTS settings. Stores base
/// language identifiers (persisted in `TTSConfiguration.language`); the
/// concrete FluidAudio 6-layer vs 24-layer pack is resolved inside
/// `TTSService` from this plus `TTSConfiguration.highQuality`.
public enum PocketTTSLanguageCatalog {
    /// Base languages in display order.
    public static let availableLanguages: [String] = [
        "english", "french", "german", "italian", "portuguese", "spanish",
    ]

    public static func displayName(for language: String) -> String {
        switch language {
        case "english": return "English"
        case "french": return "French"
        case "german": return "German"
        case "italian": return "Italian"
        case "portuguese": return "Portuguese"
        case "spanish": return "Spanish"
        default: return language.prefix(1).uppercased() + language.dropFirst()
        }
    }

    /// True when the language publishes both 6-layer and 24-layer packs, so
    /// the "higher quality" toggle is meaningful. English ships 6-layer only
    /// and French 24-layer only.
    public static func supportsQualityToggle(_ language: String) -> Bool {
        switch language {
        case "german", "italian", "portuguese", "spanish": return true
        default: return false
        }
    }

    /// True when the language only ships the 24-layer (high quality) pack;
    /// the model is always high quality regardless of the toggle (French).
    public static func isAlwaysHighQuality(_ language: String) -> Bool {
        language == "french"
    }

    /// The voice recorded natively in this language — the most idiomatic
    /// default. Falls back to the global default ("alba") for English.
    public static func nativeVoice(for language: String) -> String {
        switch language {
        case "french": return "estelle"
        case "german": return "juergen"
        case "italian": return "giovanni"
        case "portuguese": return "rafael"
        case "spanish": return "lola"
        default: return TTSConfiguration.defaultVoice
        }
    }
}

extension Notification.Name {
    /// Posted when the user taps a speaker button but the TTS model isn't ready.
    /// The app should surface the TTS settings tab so they can download the model.
    public static let openTTSSettingsRequested = Notification.Name("osaurus.openTTSSettingsRequested")

    /// Posted whenever `TTSService.playingMessageId` changes.
    /// AppKit views that can't observe `@Published` use this to refresh their speaker button icon.
    public static let ttsPlaybackStateChanged = Notification.Name("osaurus.ttsPlaybackStateChanged")

    /// Posted once when the PocketTTS model finishes loading and becomes ready.
    /// Lets a view that auto-started a download replay the originally-requested
    /// message without observing `modelState` directly (which would re-render
    /// on every progress tick).
    public static let ttsModelDidBecomeReady = Notification.Name("osaurus.ttsModelDidBecomeReady")
}
