//
//  VolcengineASRService.swift
//  Muwa
//
//  Volcengine (Doubao) BigModel streaming speech recognition client.
//
//  Implements the openspeech v3 binary WebSocket protocol:
//  4-byte header | optional Int32 big-endian sequence | UInt32 big-endian
//  payload size | payload (gzip JSON for requests/responses, gzip PCM for
//  audio). Docs: https://www.volcengine.com/docs/6561/1354869
//

@preconcurrency import AVFoundation
import Foundation
import zlib

// MARK: - Settings

public enum VolcengineASRModelService: String, CaseIterable, Sendable, Hashable {
    case bigASR = "bigasr"
    case seedASR = "seedasr"

    public var displayName: String {
        switch self {
        case .bigASR: return L("流式语音识别 1.0")
        case .seedASR: return L("流式语音识别 2.0")
        }
    }
}

public enum VolcengineASRResourceType: String, CaseIterable, Sendable, Hashable {
    case duration
    case concurrent

    public var displayName: String {
        switch self {
        case .duration: return L("小时版")
        case .concurrent: return L("并发版")
        }
    }
}

/// Resolved credentials + options for the Volcengine streaming ASR service.
public struct VolcengineASRSettings: Sendable, Equatable {
    public var apiKey: String
    public var resourceId: String

    public static let defaultModelService: VolcengineASRModelService = .bigASR
    public static let defaultResourceType: VolcengineASRResourceType = .duration
    public static let defaultResourceId = resourceId(
        modelService: defaultModelService,
        resourceType: defaultResourceType
    )
    public static let endpoint = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    public static let supportedResourceIds: Set<String> = Set(
        VolcengineASRModelService.allCases.flatMap { modelService in
            VolcengineASRResourceType.allCases.map { resourceType in
                resourceId(modelService: modelService, resourceType: resourceType)
            }
        }
    )

    public init(apiKey: String, resourceId: String) {
        self.apiKey = apiKey
        self.resourceId = resourceId
    }

    public var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !resourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func normalizedResourceId(_ resourceId: String) -> String {
        let trimmed = resourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return defaultResourceId
        }
        guard supportedResourceIds.contains(trimmed) else {
            return defaultResourceId
        }
        return trimmed
    }

    public static func resourceId(
        modelService: VolcengineASRModelService,
        resourceType: VolcengineASRResourceType
    ) -> String {
        "volc.\(modelService.rawValue).sauc.\(resourceType.rawValue)"
    }

    public static func modelService(for resourceId: String) -> VolcengineASRModelService? {
        let trimmed = resourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(".bigasr.") { return .bigASR }
        if trimmed.contains(".seedasr.") { return .seedASR }
        return nil
    }

    public static func resourceType(for resourceId: String) -> VolcengineASRResourceType? {
        let trimmed = resourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".duration") { return .duration }
        if trimmed.hasSuffix(".concurrent") { return .concurrent }
        return nil
    }

    public func requestHeaders(requestId: String = UUID().uuidString.lowercased()) -> [String: String] {
        [
            "X-Api-Key": apiKey,
            "X-Api-Resource-Id": resourceId,
            "X-Api-Request-Id": requestId,
            "X-Api-Sequence": "-1",
        ]
    }

    /// Build settings from the persisted speech configuration + Keychain token.
    @MainActor
    public static func current() -> VolcengineASRSettings {
        let config = SpeechConfigurationStore.load()
        return VolcengineASRSettings(
            apiKey: VolcengineASRKeychain.apiKey() ?? "",
            resourceId: normalizedResourceId(config.volcengineResourceId)
        )
    }
}

// MARK: - Keychain

/// Keychain storage for the Volcengine ASR API key. Caches the last
/// read so per-render UI availability checks don't hit the Keychain.
@MainActor
public enum VolcengineASRKeychain {
    private static let service = "ai.muwa.volcengine.asr"
    private static let apiKeyAccount = "apiKey"
    private static let legacyAccessTokenAccount = "accessToken"

    private static var cachedAPIKey: String??

    public static func apiKey() -> String? {
        if let cached = cachedAPIKey { return cached }
        if KeychainQueryHelpers.disablesKeychainForProcess {
            cachedAPIKey = .some(nil)
            return nil
        }
        let key = Keychain.read(service: service, account: apiKeyAccount)
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? Keychain.read(service: service, account: legacyAccessTokenAccount)
            .flatMap { String(data: $0, encoding: .utf8) }
        cachedAPIKey = .some(key)
        return key
    }

    @discardableResult
    public static func setAPIKey(_ key: String?) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedAPIKey = .some((trimmed?.isEmpty == false) ? trimmed : nil)
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        guard let trimmed, !trimmed.isEmpty else {
            let deletedCurrent = Keychain.delete(service: service, account: apiKeyAccount)
            let deletedLegacy = Keychain.delete(service: service, account: legacyAccessTokenAccount)
            return deletedCurrent || deletedLegacy
        }
        guard let data = trimmed.data(using: .utf8) else { return false }
        let wrote = Keychain.write(service: service, account: apiKeyAccount, data: data)
        _ = Keychain.delete(service: service, account: legacyAccessTokenAccount)
        return wrote
    }

    public static var hasAPIKey: Bool {
        apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public static func accessToken() -> String? {
        apiKey()
    }

    @discardableResult
    public static func setAccessToken(_ token: String?) -> Bool {
        setAPIKey(token)
    }

    public static var hasAccessToken: Bool {
        hasAPIKey
    }
}

// MARK: - Errors

public enum VolcengineASRError: Error, LocalizedError {
    case notConfigured
    case connectionFailed(String)
    case serverError(code: UInt32, message: String)
    case protocolError(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return L("火山引擎语音识别尚未配置。请在语音设置中填写 API Key 和资源 ID。")
        case .connectionFailed(let message):
            return L("无法连接火山引擎语音识别：\(message)")
        case .serverError(let code, let message):
            return "火山引擎语音识别错误 \(code)：\(message)"
        case .protocolError(let message):
            return "火山引擎语音识别协议错误：\(message)"
        case .timedOut:
            return L("火山引擎语音识别等待结果超时。")
        }
    }
}

// MARK: - Gzip (zlib)

enum VolcGzip {
    static func compress(_ data: Data) -> Data {
        var stream = z_stream()
        guard
            deflateInit2_(
                &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16,
                MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            ) == Z_OK
        else { return data }
        defer { deflateEnd(&stream) }

        var output = Data()
        var failed = false
        var finished = false

        data.withUnsafeBytes { rawBuffer in
            let bound = rawBuffer.bindMemory(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: bound.baseAddress)
            stream.avail_in = uInt(data.count)

            while !finished && !failed {
                var out = [UInt8](repeating: 0, count: 16_384)
                let status = out.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return deflate(&stream, Z_FINISH)
                }
                let used = out.count - Int(stream.avail_out)
                if used > 0 { output.append(contentsOf: out[0..<used]) }

                switch status {
                case Z_STREAM_END:
                    finished = true
                case Z_OK:
                    continue
                default:
                    failed = true
                }
            }
        }

        return failed ? data : output
    }

    static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        guard
            inflateInit2_(
                &stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
            ) == Z_OK
        else {
            throw VolcengineASRError.protocolError("Failed to initialize gzip decompression")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        var failed = false
        var finished = false

        data.withUnsafeBytes { rawBuffer in
            let bound = rawBuffer.bindMemory(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: bound.baseAddress)
            stream.avail_in = uInt(data.count)

            while !finished && !failed {
                var out = [UInt8](repeating: 0, count: 16_384)
                let status = out.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let used = out.count - Int(stream.avail_out)
                if used > 0 { output.append(contentsOf: out[0..<used]) }

                switch status {
                case Z_STREAM_END:
                    finished = true
                case Z_OK:
                    if stream.avail_in == 0 && stream.avail_out > 0 {
                        finished = true
                    }
                default:
                    failed = true
                }
            }
        }

        if failed {
            throw VolcengineASRError.protocolError("Failed to decompress gzip payload")
        }
        return output
    }
}

// MARK: - Binary frame protocol

enum VolcASRFrame {
    static let protocolVersion: UInt8 = 0b0001
    static let headerSizeWords: UInt8 = 0b0001

    // Message types
    static let fullClientRequest: UInt8 = 0b0001
    static let audioOnlyRequest: UInt8 = 0b0010
    static let fullServerResponse: UInt8 = 0b1001
    static let serverError: UInt8 = 0b1111

    // Message type specific flags
    static let flagNoSequence: UInt8 = 0b0000
    /// Last packet, without a client sequence number.
    static let flagLastPackage: UInt8 = 0b0010

    // Serialization
    static let serializationNone: UInt8 = 0b0000
    static let serializationJSON: UInt8 = 0b0001

    // Compression
    static let compressionNone: UInt8 = 0b0000
    static let compressionGzip: UInt8 = 0b0001

    static func packet(
        type: UInt8,
        flags: UInt8,
        serialization: UInt8,
        sequence: Int32?,
        payload: Data
    ) -> Data {
        var data = Data(capacity: payload.count + 12)
        data.append((protocolVersion << 4) | headerSizeWords)
        data.append((type << 4) | flags)
        data.append((serialization << 4) | compressionGzip)
        data.append(0x00)
        if let sequence {
            withUnsafeBytes(of: sequence.bigEndian) { data.append(contentsOf: $0) }
        }
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    struct ServerMessage {
        var type: UInt8
        var flags: UInt8
        var sequence: Int32?
        var payload: [String: Any]?
        var errorCode: UInt32?
        var errorMessage: String?

        var isLastPackage: Bool {
            if let sequence, sequence < 0 { return true }
            if (flags & 0b0010) != 0 { return true }
            if let payload, let last = payload["is_last_package"] as? Bool { return last }
            return false
        }
    }

    static func parse(_ data: Data) throws -> ServerMessage {
        guard data.count >= 4 else {
            throw VolcengineASRError.protocolError("Response too short (\(data.count) bytes)")
        }
        let bytes = [UInt8](data)
        let headerBytes = max(4, Int(bytes[0] & 0x0F) * 4)
        let type = (bytes[1] >> 4) & 0x0F
        let flags = bytes[1] & 0x0F
        let compression = bytes[2] & 0x0F
        var cursor = headerBytes

        func readUInt32() throws -> UInt32 {
            guard data.count >= cursor + 4 else {
                throw VolcengineASRError.protocolError("Truncated response")
            }
            let value =
                UInt32(bytes[cursor]) << 24 | UInt32(bytes[cursor + 1]) << 16
                | UInt32(bytes[cursor + 2]) << 8 | UInt32(bytes[cursor + 3])
            cursor += 4
            return value
        }

        var message = ServerMessage(type: type, flags: flags)

        if type == serverError {
            message.errorCode = try readUInt32()
            let payloadSize = Int(try readUInt32())
            let raw = data.subdata(in: cursor..<min(cursor + payloadSize, data.count))
            let decoded = (try? VolcGzip.decompress(raw)) ?? raw
            message.errorMessage = String(data: decoded, encoding: .utf8) ?? ""
            return message
        }

        guard type == fullServerResponse else {
            // Ignore anything we don't understand (e.g. server ACK variants).
            return message
        }

        if (flags & 0b0001) != 0 {
            message.sequence = Int32(bitPattern: try readUInt32())
        }

        let payloadSize = Int(try readUInt32())
        guard payloadSize > 0, data.count >= cursor + payloadSize else {
            return message
        }
        var payloadData = data.subdata(in: cursor..<(cursor + payloadSize))
        if compression == compressionGzip
            || (payloadData.count >= 2 && payloadData[payloadData.startIndex] == 0x1F
                && payloadData[payloadData.startIndex + 1] == 0x8B)
        {
            payloadData = try VolcGzip.decompress(payloadData)
        }
        message.payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        return message
    }
}

// MARK: - Streaming session

/// Incremental updates from a live recognition session. Mirrors the local
/// worker semantics: `.final` text segments accumulate, `.partial` replaces
/// the in-progress preview.
enum VolcASRUpdate: Sendable {
    case partial(String)
    case final(String)
}

/// One WebSocket connection to the Volcengine streaming ASR service.
///
/// Lifecycle: `connect()` → repeated `sendAudio(_:)` → `finishAndCollect()`.
/// Incremental results flow through `updates`; `finishAndCollect()` switches
/// the session to collecting mode so the trailing results are returned to the
/// caller instead of racing the stream consumer during teardown.
actor VolcengineASRSession {
    private let settings: VolcengineASRSettings
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?

    private var continuation: AsyncStream<VolcASRUpdate>.Continuation?
    let updates: AsyncStream<VolcASRUpdate>

    private var emittedDefiniteCount = 0
    private var lastPartialText = ""
    private var receivedLastPackage = false
    private var lastErrorMessage: String?

    /// When true, `.final` segments append to `collectedFinals` instead of
    /// being yielded to `updates`.
    private var isCollecting: Bool
    private var collectedFinals: [String] = []
    private var completionContinuations: [CheckedContinuation<Void, Never>] = []

    init(settings: VolcengineASRSettings, collectOnly: Bool = false) {
        self.settings = settings
        self.isCollecting = collectOnly
        var continuation: AsyncStream<VolcASRUpdate>.Continuation?
        self.updates = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    // MARK: Connection

    func connect() async throws {
        guard settings.isConfigured else { throw VolcengineASRError.notConfigured }

        guard let url = URL(string: VolcengineASRSettings.endpoint) else {
            throw VolcengineASRError.connectionFailed("Invalid endpoint")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        for (field, value) in settings.requestHeaders() {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 10 * 1024 * 1024
        task.resume()
        self.urlSession = session
        self.webSocket = task

        // Full client request. Client request frames do not carry sequence bytes.
        let payload = try fullClientRequestPayload()
        let packet = VolcASRFrame.packet(
            type: VolcASRFrame.fullClientRequest,
            flags: VolcASRFrame.flagNoSequence,
            serialization: VolcASRFrame.serializationJSON,
            sequence: nil,
            payload: VolcGzip.compress(payload)
        )
        do {
            try await task.send(.data(packet))
        } catch {
            close()
            throw VolcengineASRError.connectionFailed(error.localizedDescription)
        }

        // Handshake: the first server frame either acknowledges the request
        // or reports an auth/config error. Surface the latter to the caller.
        let first = try await receiveMessage(task)
        let parsed = try VolcASRFrame.parse(first)
        if parsed.type == VolcASRFrame.serverError {
            close()
            throw VolcengineASRError.serverError(
                code: parsed.errorCode ?? 0,
                message: parsed.errorMessage ?? "Unknown error"
            )
        }
        handle(parsed)

        startReceiveLoop()
    }

    private func fullClientRequestPayload() throws -> Data {
        let audio: [String: Any] = [
            "format": "pcm",
            "codec": "raw",
            "rate": 16_000,
            "bits": 16,
            "channel": 1,
        ]
        let request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_nonstream": true,
            "enable_itn": true,
            "enable_punc": true,
            "show_utterances": true,
            "end_window_size": 800,
        ]
        let payload: [String: Any] = [
            "user": ["uid": "muwa"],
            "audio": audio,
            "request": request,
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func receiveMessage(_ task: URLSessionWebSocketTask) async throws -> Data {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw VolcengineASRError.connectionFailed(error.localizedDescription)
        }
        switch message {
        case .data(let data): return data
        case .string(let string): return Data(string.utf8)
        @unknown default:
            throw VolcengineASRError.protocolError("Unexpected message kind")
        }
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            while let self, await !self.isFinished {
                guard let socket = await self.webSocket else { break }
                do {
                    let data = try await self.receiveMessage(socket)
                    let parsed = try VolcASRFrame.parse(data)
                    await self.handle(parsed)
                } catch {
                    await self.handleReceiveFailure(error)
                    break
                }
            }
        }
    }

    private var isFinished: Bool { receivedLastPackage || webSocket == nil }

    private func handleReceiveFailure(_ error: Error) {
        if !receivedLastPackage {
            lastErrorMessage = error.localizedDescription
            print("[VolcengineASR] Receive failed: \(error)")
        }
        markCompleted()
    }

    // MARK: Response handling

    private func handle(_ message: VolcASRFrame.ServerMessage) {
        if message.type == VolcASRFrame.serverError {
            lastErrorMessage = "\(message.errorCode ?? 0): \(message.errorMessage ?? "")"
            print("[VolcengineASR] Server error \(lastErrorMessage ?? "")")
            markCompleted()
            return
        }

        if let payload = message.payload, let result = payload["result"] as? [String: Any] {
            if let utterances = result["utterances"] as? [[String: Any]] {
                let definite = utterances.filter { ($0["definite"] as? Bool) == true }
                if definite.count > emittedDefiniteCount {
                    for utterance in definite[emittedDefiniteCount...] {
                        if let text = utterance["text"] as? String, !text.isEmpty {
                            emitFinal(text)
                        }
                    }
                    emittedDefiniteCount = definite.count
                }
                let inProgress = utterances.last { ($0["definite"] as? Bool) != true }
                lastPartialText = (inProgress?["text"] as? String) ?? ""
                if !isCollecting {
                    continuation?.yield(.partial(lastPartialText))
                }
            } else if let text = result["text"] as? String {
                lastPartialText = text
                if !isCollecting {
                    continuation?.yield(.partial(text))
                }
            }
        }

        if message.isLastPackage {
            // Flush any in-progress utterance the server never marked definite.
            let trailing = lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty {
                emitFinal(trailing)
                lastPartialText = ""
            }
            markCompleted()
        }
    }

    private func emitFinal(_ text: String) {
        if isCollecting {
            collectedFinals.append(text)
        } else {
            continuation?.yield(.final(text))
        }
    }

    private func markCompleted() {
        receivedLastPackage = true
        continuation?.finish()
        for waiter in completionContinuations {
            waiter.resume()
        }
        completionContinuations.removeAll()
    }

    // MARK: Sending

    func sendAudio(_ pcm16: Data) async throws {
        guard let socket = webSocket, !receivedLastPackage else { return }
        let packet = VolcASRFrame.packet(
            type: VolcASRFrame.audioOnlyRequest,
            flags: VolcASRFrame.flagNoSequence,
            serialization: VolcASRFrame.serializationNone,
            sequence: nil,
            payload: VolcGzip.compress(pcm16)
        )
        try await socket.send(.data(packet))
    }

    /// Send the final packet, then wait for the server's
    /// last result. Returns the text segments produced after collecting mode
    /// was switched on, joined in order.
    func finishAndCollect(timeoutSeconds: Double = 8) async -> String {
        isCollecting = true

        if let socket = webSocket, !receivedLastPackage {
            let packet = VolcASRFrame.packet(
                type: VolcASRFrame.audioOnlyRequest,
                flags: VolcASRFrame.flagLastPackage,
                serialization: VolcASRFrame.serializationNone,
                sequence: nil,
                payload: VolcGzip.compress(Data())
            )
            try? await socket.send(.data(packet))
        }

        await waitForCompletion(timeoutSeconds: timeoutSeconds)
        close()

        return collectedFinals.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitForCompletion(timeoutSeconds: Double) async {
        if receivedLastPackage { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            completionContinuations.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                await self?.timeOutCompletion()
            }
        }
    }

    private func timeOutCompletion() {
        if !receivedLastPackage {
            print("[VolcengineASR] Timed out waiting for final result")
            markCompleted()
        }
    }

    func close() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        continuation?.finish()
    }

    // MARK: One-shot transcription

    /// Transcribe a complete 16 kHz mono Float32 buffer in a single session.
    static func transcribe(samples: [Float], settings: VolcengineASRSettings) async throws -> String {
        let session = VolcengineASRSession(settings: settings, collectOnly: true)
        try await session.connect()

        // 200 ms chunks (3200 samples at 16 kHz)
        let chunkSize = 3_200
        var index = 0
        while index < samples.count {
            let end = min(index + chunkSize, samples.count)
            let chunk = Array(samples[index..<end])
            try await session.sendAudio(Self.pcm16Data(from: chunk))
            index = end
        }

        let text = await session.finishAndCollect(timeoutSeconds: 30)
        if text.isEmpty, let error = await session.lastError {
            throw VolcengineASRError.connectionFailed(error)
        }
        return text
    }

    var lastError: String? { lastErrorMessage }

    static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data(count: samples.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            let out = rawBuffer.bindMemory(to: Int16.self)
            for (index, sample) in samples.enumerated() {
                let clamped = max(-1.0, min(1.0, sample))
                out[index] = Int16(clamped * Float(Int16.max))
            }
        }
        return data
    }
}

// MARK: - Cloud transcription worker

/// Streaming worker backed by the Volcengine cloud ASR session. Mirrors the
/// local FluidAudio `TranscriptionWorker`: drains the shared audio buffer,
/// forwards PCM to the server, and republishes results as
/// `TranscriptionUpdate`s. Speech activity is approximated from RMS level —
/// the server performs its own utterance segmentation.
actor CloudTranscriptionWorker: TranscriptionWorking {
    private let session: VolcengineASRSession
    private let audioBuffer: ThreadSafeAudioBuffer
    private let inputFormat: AVAudioFormat
    private let needsConversion: Bool
    private let targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private var task: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?
    private var continuation: AsyncStream<TranscriptionUpdate>.Continuation?
    private var connectionError: String?

    /// RMS threshold above which a chunk counts as speech (matches the local
    /// worker's energy fallback).
    private let speechRMSThreshold: Float = 0.005

    init(
        settings: VolcengineASRSettings,
        audioBuffer: ThreadSafeAudioBuffer,
        inputFormat: AVAudioFormat
    ) {
        self.session = VolcengineASRSession(settings: settings)
        self.audioBuffer = audioBuffer
        self.inputFormat = inputFormat
        self.needsConversion = inputFormat.sampleRate != 16_000
        self.targetFormat =
            needsConversion
            ? AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
            : nil
    }

    func start() -> AsyncStream<TranscriptionUpdate> {
        let stream = AsyncStream<TranscriptionUpdate> { continuation in
            self.continuation = continuation
        }
        task = Task { [weak self] in
            await self?.runLoop()
        }
        return stream
    }

    func stop() {
        task?.cancel()
        forwardTask?.cancel()
        continuation?.finish()
        task = nil
        forwardTask = nil
        continuation = nil
        Task { await session.close() }
    }

    /// Drain remaining audio, signal end-of-stream, and wait for the trailing
    /// recognition result. Returns the text not yet delivered via `start()`.
    func finalize() async -> String? {
        task?.cancel()
        task = nil

        let remaining = audioBuffer.getAndClear()
        if !remaining.isEmpty {
            let converted = convertTo16kHz(remaining)
            if !converted.isEmpty {
                try? await session.sendAudio(VolcengineASRSession.pcm16Data(from: converted))
            }
        }

        let text = await session.finishAndCollect()
        forwardTask?.cancel()
        forwardTask = nil
        return text
    }

    private func runLoop() async {
        if needsConversion, let targetFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            if converter == nil {
                print("[CloudTranscriptionWorker] Failed to create audio converter")
            }
        }

        do {
            try await session.connect()
        } catch {
            print("[CloudTranscriptionWorker] Connection failed: \(error)")
            connectionError = error.localizedDescription
            continuation?.finish()
            return
        }

        // Forward server results onto the worker's update stream.
        forwardTask = Task { [weak self] in
            guard let self else { return }
            for await update in await self.sessionUpdates() {
                switch update {
                case .partial(let text):
                    await self.yield(.partial(text))
                case .final(let text):
                    await self.yield(.final(text))
                }
            }
        }

        var lastReportedSpeechActivity = false

        while audioBuffer.isActive && !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                break
            }
            guard audioBuffer.isActive else { break }

            let rawSamples = audioBuffer.getAndClear()
            guard !rawSamples.isEmpty else { continue }

            let converted = convertTo16kHz(rawSamples)
            guard !converted.isEmpty else { continue }

            let sum = converted.reduce(Float(0)) { $0 + $1 * $1 }
            let rms = sqrt(sum / Float(converted.count))
            let speechDetected = rms > speechRMSThreshold
            if speechDetected != lastReportedSpeechActivity {
                lastReportedSpeechActivity = speechDetected
                continuation?.yield(.speechActivity(speechDetected))
            }

            do {
                try await session.sendAudio(VolcengineASRSession.pcm16Data(from: converted))
            } catch {
                print("[CloudTranscriptionWorker] Send failed: \(error)")
                break
            }
        }

        if lastReportedSpeechActivity {
            continuation?.yield(.speechActivity(false))
        }
    }

    private func sessionUpdates() -> AsyncStream<VolcASRUpdate> {
        session.updates
    }

    private func yield(_ update: TranscriptionUpdate) {
        continuation?.yield(update)
    }

    private func convertTo16kHz(_ samples: [Float]) -> [Float] {
        guard needsConversion else { return samples }
        guard let converter, let targetFormat else { return [] }

        let inputFrameCount = AVAudioFrameCount(samples.count)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount)
        else { return [] }

        inputBuffer.frameLength = inputFrameCount
        if let channelData = inputBuffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { ptr in
                channelData.update(from: ptr.baseAddress!, count: samples.count)
            }
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(inputFrameCount) * ratio) + 100
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity)
        else { return [] }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        if error != nil { return [] }

        if let floatData = outputBuffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: floatData, count: Int(outputBuffer.frameLength)))
        }
        return []
    }
}
