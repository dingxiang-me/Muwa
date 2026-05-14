import Foundation

public protocol ServerConfigurationProvider: Sendable {
    func load() async -> ServerConfiguration?
}

public protocol ModelDirectoryProvider: Sendable {
    func effectiveModelsDirectory() -> URL
}

public protocol ModelLocator: Sendable {
    func installedModelNames() -> [String]
    func findInstalledModel(named name: String) -> (name: String, id: String)?
}

public protocol ModelListProvider: Sendable {
    func isFoundationModelAvailable() -> Bool
    func availableRemoteModels() async -> [OpenAIModel]
}

public protocol Telemetry: Sendable {
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
public protocol AgentProvider: Sendable {
    func effectiveModel(for agentId: UUID) async -> String?
    func autonomousExecEnabled(for agentId: UUID) async -> Bool
    func resolveAgentId(_ identifier: String) async -> UUID?
}

public struct ToolListEntry: Sendable {
    let name: String
    let description: String
    let parameters: JSONValue?
}

/// Host-supplied tool registry used by HTTPHandler. The "always-loaded
/// specs" call resolves capability/folder filters internally — the
/// engine just passes the `autonomousEnabled` agent flag through.
public protocol ToolExecutor: Sendable {
    func alwaysLoadedSpecs(autonomousEnabled: Bool) async -> [Tool]
    func listEnabledTools() async -> [ToolListEntry]
    func parameters(forTool name: String) async -> JSONValue?
    func execute(name: String, argumentsJSON: String) async throws -> String
}

/// Narrow surface that HTTPHandler's memory-ingest + agents-list
/// endpoints need. Standalone CLI uses the no-op default; this entire
/// endpoint group is app-specific and will likely move out of
/// HTTPHandler in a later refactor.
public protocol MemoryProvider: Sendable {
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
public protocol AgentEnricher: Sendable {
    func enrich(_ request: ChatCompletionRequest, agentId: String) async -> ChatCompletionRequest
}

public protocol TunnelResolver: Sendable {
    func tunnelBaseURL(for agentId: UUID) async -> String?
}

public protocol DownloadVerifier: Sendable {
    func ensureComplete(modelId: String, name: String, directory: URL) async
    func resolveURL(repoId: String, path: String) -> URL?
}

public struct DefaultServerConfigurationProvider: ServerConfigurationProvider {
    func load() async -> ServerConfiguration? { nil }
}

/// Defaults to `~/.osaurus/models`. CLI overrides via `--model-dir`.
public struct DefaultModelDirectoryProvider: ModelDirectoryProvider {
    func effectiveModelsDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".osaurus/models", isDirectory: true)
    }
}

public struct NoOpModelLocator: ModelLocator {
    func installedModelNames() -> [String] { [] }
    func findInstalledModel(named name: String) -> (name: String, id: String)? { nil }
}

public struct NoOpModelListProvider: ModelListProvider {
    func isFoundationModelAvailable() -> Bool { false }
    func availableRemoteModels() async -> [OpenAIModel] { [] }
}

public struct NoOpTelemetry: Telemetry {
    func logRequest(
        method: String, path: String, userAgent: String?,
        requestBody: String?, responseBody: String?,
        responseStatus: Int, durationMs: Double, model: String?,
        tokensInput: Int?, tokensOutput: Int?, temperature: Float?,
        maxTokens: Int?, toolCalls: [ToolCallLog]?,
        finishReason: RequestLog.FinishReason?, errorMessage: String?
    ) {}
}

public struct NoOpAgentProvider: AgentProvider {
    func effectiveModel(for agentId: UUID) async -> String? { nil }
    func autonomousExecEnabled(for agentId: UUID) async -> Bool { false }
    func resolveAgentId(_ identifier: String) async -> UUID? { nil }
}

public struct NoOpToolExecutor: ToolExecutor {
    func alwaysLoadedSpecs(autonomousEnabled: Bool) async -> [Tool] { [] }
    func listEnabledTools() async -> [ToolListEntry] { [] }
    func parameters(forTool name: String) async -> JSONValue? { nil }
    func execute(name: String, argumentsJSON: String) async throws -> String {
        throw NSError(
            domain: "ToolExecutor", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No tool executor registered: \(name)"]
        )
    }
}

public struct NoOpMemoryProvider: MemoryProvider {
    var isOpen: Bool { false }
    func deleteTranscriptForConversation(_ conversationId: String) throws {}
    func insertTranscriptTurn(
        agentId: String, conversationId: String, chunkIndex: Int,
        role: String, content: String, tokenCount: Int, createdAt: String?
    ) throws {}
    func agentIdsWithPinnedFacts() throws -> [(agentId: String, count: Int)] { [] }
}

public struct NoOpAgentEnricher: AgentEnricher {
    func enrich(_ request: ChatCompletionRequest, agentId: String) async -> ChatCompletionRequest {
        request
    }
}

public struct NoOpTunnelResolver: TunnelResolver {
    func tunnelBaseURL(for agentId: UUID) async -> String? { nil }
}

public struct NoOpDownloadVerifier: DownloadVerifier {
    func ensureComplete(modelId: String, name: String, directory: URL) async {}
    func resolveURL(repoId: String, path: String) -> URL? { nil }
}
