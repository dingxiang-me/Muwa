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

protocol DownloadVerifier: Sendable {
    func ensureComplete(modelId: String, name: String, directory: URL) async
    func resolveURL(repoId: String, path: String) -> URL?
}

struct DefaultServerConfigurationProvider: ServerConfigurationProvider {
    func load() async -> ServerConfiguration? { nil }
}

/// Defaults to `~/.osaurus/models`. CLI overrides via `--model-dir`.
struct DefaultModelDirectoryProvider: ModelDirectoryProvider {
    func effectiveModelsDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".osaurus/models", isDirectory: true)
    }
}

struct NoOpModelLocator: ModelLocator {
    func installedModelNames() -> [String] { [] }
    func findInstalledModel(named name: String) -> (name: String, id: String)? { nil }
}

struct NoOpModelListProvider: ModelListProvider {
    func isFoundationModelAvailable() -> Bool { false }
    func availableRemoteModels() async -> [OpenAIModel] { [] }
}

struct NoOpTelemetry: Telemetry {
    func logRequest(
        method: String, path: String, userAgent: String?,
        requestBody: String?, responseBody: String?,
        responseStatus: Int, durationMs: Double, model: String?,
        tokensInput: Int?, tokensOutput: Int?, temperature: Float?,
        maxTokens: Int?, toolCalls: [ToolCallLog]?,
        finishReason: RequestLog.FinishReason?, errorMessage: String?
    ) {}
}

struct NoOpDownloadVerifier: DownloadVerifier {
    func ensureComplete(modelId: String, name: String, directory: URL) async {}
    func resolveURL(repoId: String, path: String) -> URL? { nil }
}
