import Foundation

struct AppServerConfigurationProvider: ServerConfigurationProvider {
    func load() async -> ServerConfiguration? {
        await MainActor.run { ServerConfigurationStore.load() }
    }
}

struct AppModelDirectoryProvider: ModelDirectoryProvider {
    func effectiveModelsDirectory() -> URL {
        DirectoryPickerService.effectiveModelsDirectory()
    }
}

struct AppModelLocator: ModelLocator {
    func installedModelNames() -> [String] {
        ModelManager.installedModelNames()
    }
    func findInstalledModel(named name: String) -> (name: String, id: String)? {
        ModelManager.findInstalledModel(named: name)
    }
}

struct AppModelListProvider: ModelListProvider {
    func isFoundationModelAvailable() -> Bool {
        FoundationModelService.isDefaultModelAvailable()
    }
    func availableRemoteModels() async -> [OpenAIModel] {
        await MainActor.run { RemoteProviderManager.shared.getOpenAIModels() }
    }
}

struct AppTelemetry: Telemetry {
    func logRequest(
        method: String, path: String, userAgent: String?,
        requestBody: String?, responseBody: String?,
        responseStatus: Int, durationMs: Double, model: String?,
        tokensInput: Int?, tokensOutput: Int?, temperature: Float?,
        maxTokens: Int?, toolCalls: [ToolCallLog]?,
        finishReason: RequestLog.FinishReason?, errorMessage: String?
    ) {
        InsightsService.logAsync(
            method: method, path: path, userAgent: userAgent,
            requestBody: requestBody, responseBody: responseBody,
            responseStatus: responseStatus, durationMs: durationMs,
            model: model, tokensInput: tokensInput, tokensOutput: tokensOutput,
            temperature: temperature, maxTokens: maxTokens,
            toolCalls: toolCalls, finishReason: finishReason,
            errorMessage: errorMessage
        )
    }
}

struct AppDownloadVerifier: DownloadVerifier {
    func ensureComplete(modelId: String, name: String, directory: URL) async {
        let probe = MLXModel(id: modelId, name: name, description: "", downloadURL: "")
        await ModelDownloadService.ensureComplete(for: probe, directory: directory)
    }

    func resolveURL(repoId: String, path: String) -> URL? {
        ModelDownloadService.resolveURL(repoId: repoId, path: path)
    }
}
