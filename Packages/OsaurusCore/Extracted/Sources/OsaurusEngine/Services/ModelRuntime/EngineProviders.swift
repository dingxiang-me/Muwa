import Foundation

protocol ServerConfigurationProvider: Sendable {
    func load() async -> ServerConfiguration?
}

protocol ModelDirectoryProvider: Sendable {
    func effectiveModelsDirectory() -> URL
}

protocol ModelLocator: Sendable {
    func installedModelNames() -> [String]
    func findInstalledModel(named name: String) -> (name: String, id: String)?
}

protocol ModelListProvider: Sendable {
    func isFoundationModelAvailable() -> Bool
    func availableRemoteModels() async -> [OpenAIModel]
}

protocol Telemetry: Sendable {
    func logRequest(
        method: String,
        path: String,
        userAgent: String?,
        requestBody: String?,
        responseBody: String?,
        responseStatus: Int,
        durationMs: Double,
        model: String?,
        tokensInput: Int?,
        tokensOutput: Int?,
        temperature: Float?,
        maxTokens: Int?,
        toolCalls: [ToolCallLog]?,
        finishReason: RequestLog.FinishReason?,
        errorMessage: String?
    )
}

/// Engine-side surface for agent-scoped chat completions and
/// `/agent/{id}/...` routing. The wider agent concept (pairing,
/// invites, listing, per-agent crypto keys) is app-specific and
/// stays on `AgentManager` directly in HTTPHandler endpoints that
/// will relocate out of the engine in a later phase.
protocol AgentProvider: Sendable {
    func effectiveModel(for agentId: UUID) async -> String?
    func autonomousExecEnabled(for agentId: UUID) async -> Bool
    func resolveAgentId(_ identifier: String) async -> UUID?
}

struct ToolListEntry: Sendable {
    public let name: String
    public let description: String
    public let parameters: JSONValue?
}

/// Host-supplied tool registry used by HTTPHandler. The "always-loaded
/// specs" call resolves capability/folder filters internally — the
/// engine just passes the `autonomousEnabled` agent flag through.
protocol ToolExecutor: Sendable {
    func alwaysLoadedSpecs(autonomousEnabled: Bool) async -> [Tool]
    func listEnabledTools() async -> [ToolListEntry]
    func parameters(forTool name: String) async -> JSONValue?
    func execute(name: String, argumentsJSON: String) async throws -> String
}

/// Narrow surface that HTTPHandler's memory-ingest + agents-list
/// endpoints need. Standalone CLI uses the no-op default; this entire
/// endpoint group is app-specific and will likely move out of
/// HTTPHandler in a later refactor.
protocol MemoryProvider: Sendable {
    var isOpen: Bool { get }
    func deleteTranscriptForConversation(_ conversationId: String) throws
    func insertTranscriptTurn(
        agentId: String, conversationId: String, chunkIndex: Int,
        role: String, content: String, tokenCount: Int, createdAt: String?
    ) throws
    func agentIdsWithPinnedFacts() throws -> [(agentId: String, count: Int)]
}

/// Enriches a chat completion request with agent-scoped context
/// (system prompt + memory section) before it hits the engine. Host
/// resolves agent id → agent record → prompt composer; CLI uses the
/// no-op default and passes the request through unchanged.
protocol AgentEnricher: Sendable {
    func enrich(_ request: ChatCompletionRequest, agentId: String) async -> ChatCompletionRequest
}

protocol TunnelResolver: Sendable {
    func tunnelBaseURL(for agentId: UUID) async -> String?
}

protocol DownloadVerifier: Sendable {
    func ensureComplete(modelId: String, name: String, directory: URL) async
    func resolveURL(repoId: String, path: String) -> URL?
}

/// Persists a completed chat-completion round. Engine HTTPHandler invokes
/// this after streaming finishes; Mac app writes to ChatHistoryDatabase,
/// CLI uses the no-op default.
protocol ChatHistoryPersister: Sendable {
    func persist(
        sourceTag: String,
        sourcePluginId: String?,
        agentId: UUID?,
        externalKey: String?,
        finalMessages: [ChatMessage],
        model: String
    ) async
}

/// Computes vector embeddings for /v1/embeddings.
protocol EmbeddingProvider: Sendable {
    var modelName: String { get }
    func embed(texts: [String]) async throws -> [[Float]]
}

/// Handles /v1/audio/transcriptions. Returns text and optional duration.
protocol SpeechProvider: Sendable {
    func transcribe(audioURL: URL) async throws -> (text: String, durationSeconds: TimeInterval?)
}

/// Provides the chat-completion brain (model routing + service dispatch).
/// Mac app registers the full `ChatEngine` with `RemoteProviderManager`
/// + `InsightsService`; CLI registers a slimmer engine that only knows
/// about MLX. Engine HTTPHandler reads from the seam when no explicit
/// engine was passed to its init.
protocol ChatEngineProvider: Sendable {
    func makeChatEngine() -> any ChatEngineProtocol
}

/// Backs `/agents/{id}/dispatch`, `GET /tasks/{id}`, `DELETE /tasks/{id}`.
/// Mac app implements via `TaskDispatcher`/`BackgroundTaskManager`; CLI
/// uses the no-op default and these endpoints return errors.
protocol BackgroundTaskService: Sendable {
    /// Returns resolved task id (may differ from requestId when the
    /// dispatcher reattaches to an existing session), or nil if the
    /// task limit was reached.
    func dispatchHTTPTask(
        requestId: UUID,
        prompt: String,
        agentId: UUID,
        title: String?,
        externalSessionKey: String?
    ) async -> UUID?

    /// Serialized task state JSON, or nil if the task is not found.
    func taskStateJSON(id: UUID) async -> String?

    /// Fire-and-forget cancel. Matches the host's existing semantics.
    func cancel(id: UUID) async
}

struct DefaultServerConfigurationProvider: ServerConfigurationProvider {
    public func load() async -> ServerConfiguration? { nil }
}

/// Defaults to `~/.osaurus/models`. CLI overrides via `--model-dir`.
struct DefaultModelDirectoryProvider: ModelDirectoryProvider {
    public func effectiveModelsDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".osaurus/models", isDirectory: true)
    }
}

struct NoOpModelLocator: ModelLocator {
    public func installedModelNames() -> [String] { [] }
    public func findInstalledModel(named name: String) -> (name: String, id: String)? { nil }
}

struct NoOpModelListProvider: ModelListProvider {
    public func isFoundationModelAvailable() -> Bool { false }
    public func availableRemoteModels() async -> [OpenAIModel] { [] }
}

struct NoOpTelemetry: Telemetry {
    public func logRequest(
        method: String, path: String, userAgent: String?,
        requestBody: String?, responseBody: String?,
        responseStatus: Int, durationMs: Double, model: String?,
        tokensInput: Int?, tokensOutput: Int?, temperature: Float?,
        maxTokens: Int?, toolCalls: [ToolCallLog]?,
        finishReason: RequestLog.FinishReason?, errorMessage: String?
    ) {}
}

struct NoOpAgentProvider: AgentProvider {
    public func effectiveModel(for agentId: UUID) async -> String? { nil }
    public func autonomousExecEnabled(for agentId: UUID) async -> Bool { false }
    public func resolveAgentId(_ identifier: String) async -> UUID? { nil }
}

struct NoOpToolExecutor: ToolExecutor {
    public func alwaysLoadedSpecs(autonomousEnabled: Bool) async -> [Tool] { [] }
    public func listEnabledTools() async -> [ToolListEntry] { [] }
    public func parameters(forTool name: String) async -> JSONValue? { nil }
    public func execute(name: String, argumentsJSON: String) async throws -> String {
        throw NSError(
            domain: "ToolExecutor", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No tool executor registered: \(name)"]
        )
    }
}

struct NoOpMemoryProvider: MemoryProvider {
    public var isOpen: Bool { false }
    public func deleteTranscriptForConversation(_ conversationId: String) throws {}
    public func insertTranscriptTurn(
        agentId: String, conversationId: String, chunkIndex: Int,
        role: String, content: String, tokenCount: Int, createdAt: String?
    ) throws {}
    public func agentIdsWithPinnedFacts() throws -> [(agentId: String, count: Int)] { [] }
}

struct NoOpAgentEnricher: AgentEnricher {
    public func enrich(_ request: ChatCompletionRequest, agentId: String) async -> ChatCompletionRequest {
        request
    }
}

struct NoOpTunnelResolver: TunnelResolver {
    public func tunnelBaseURL(for agentId: UUID) async -> String? { nil }
}

struct NoOpDownloadVerifier: DownloadVerifier {
    public func ensureComplete(modelId: String, name: String, directory: URL) async {}
    public func resolveURL(repoId: String, path: String) -> URL? { nil }
}

struct NoOpChatHistoryPersister: ChatHistoryPersister {
    public func persist(
        sourceTag: String,
        sourcePluginId: String?,
        agentId: UUID?,
        externalKey: String?,
        finalMessages: [ChatMessage],
        model: String
    ) async {}
}

struct NoOpEmbeddingProvider: EmbeddingProvider {
    public var modelName: String { "" }
    public func embed(texts: [String]) async throws -> [[Float]] {
        throw NSError(
            domain: "EmbeddingProvider", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No embedding provider registered"]
        )
    }
}

struct NoOpSpeechProvider: SpeechProvider {
    public func transcribe(audioURL: URL) async throws -> (text: String, durationSeconds: TimeInterval?) {
        throw NSError(
            domain: "SpeechProvider", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No speech provider registered"]
        )
    }
}

struct NoOpChatEngine: ChatEngineProtocol {
    public func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        throw ChatEngineError(kind: .noServiceAvailable(requested: request.model))
    }
    public func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw ChatEngineError(kind: .noServiceAvailable(requested: request.model))
    }
}

struct NoOpChatEngineProvider: ChatEngineProvider {
    public func makeChatEngine() -> any ChatEngineProtocol { NoOpChatEngine() }
}

struct NoOpBackgroundTaskService: BackgroundTaskService {
    public func dispatchHTTPTask(
        requestId: UUID,
        prompt: String,
        agentId: UUID,
        title: String?,
        externalSessionKey: String?
    ) async -> UUID? { nil }
    public func taskStateJSON(id: UUID) async -> String? { nil }
    public func cancel(id: UUID) async {}
}
