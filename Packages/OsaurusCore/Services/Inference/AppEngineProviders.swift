import Foundation

public struct AppServerConfigurationProvider: ServerConfigurationProvider {
    public init() {}
    public func load() async -> ServerConfiguration? {
        await MainActor.run { ServerConfigurationStore.load() }
    }
}

public struct AppModelDirectoryProvider: ModelDirectoryProvider {
    public init() {}
    public func effectiveModelsDirectory() -> URL {
        DirectoryPickerService.effectiveModelsDirectory()
    }
}

public struct AppDownloadVerifier: DownloadVerifier {
    public init() {}

    public func ensureComplete(modelId: String, name: String, directory: URL) async {
        let probe = MLXModel(id: modelId, name: name, description: "", downloadURL: "")
        await ModelDownloadService.ensureComplete(for: probe, directory: directory)
    }

    public func resolveURL(repoId: String, path: String) -> URL? {
        ModelDownloadService.resolveURL(repoId: repoId, path: path)
    }
}
