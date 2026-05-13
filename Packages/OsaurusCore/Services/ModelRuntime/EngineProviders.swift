import Foundation

public protocol ServerConfigurationProvider: Sendable {
    func load() async -> ServerConfiguration?
}

public protocol ModelDirectoryProvider: Sendable {
    func effectiveModelsDirectory() -> URL
}

public protocol DownloadVerifier: Sendable {
    func ensureComplete(modelId: String, name: String, directory: URL) async
    func resolveURL(repoId: String, path: String) -> URL?
}

public struct DefaultServerConfigurationProvider: ServerConfigurationProvider {
    public init() {}
    public func load() async -> ServerConfiguration? { nil }
}

/// Defaults to `~/.osaurus/models`. CLI overrides via `--model-dir`.
public struct DefaultModelDirectoryProvider: ModelDirectoryProvider {
    public init() {}
    public func effectiveModelsDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".osaurus/models", isDirectory: true)
    }
}

public struct NoOpDownloadVerifier: DownloadVerifier {
    public init() {}
    public func ensureComplete(modelId: String, name: String, directory: URL) async {}
    public func resolveURL(repoId: String, path: String) -> URL? { nil }
}
