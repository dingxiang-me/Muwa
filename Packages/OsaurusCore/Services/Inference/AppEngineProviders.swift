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

struct AppAgentProvider: AgentProvider {
    func effectiveModel(for agentId: UUID) async -> String? {
        await MainActor.run { AgentManager.shared.effectiveModel(for: agentId) }
    }
    func autonomousExecEnabled(for agentId: UUID) async -> Bool {
        await MainActor.run {
            AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true
        }
    }
    func resolveAgentId(_ identifier: String) async -> UUID? {
        await MainActor.run { AgentManager.shared.resolveAgentId(identifier) }
    }
}

struct AppToolExecutor: ToolExecutor {
    func alwaysLoadedSpecs(autonomousEnabled: Bool) async -> [Tool] {
        await MainActor.run {
            let mode = ToolRegistry.shared.resolveExecutionMode(
                folderContext: nil, autonomousEnabled: autonomousEnabled
            )
            return ToolRegistry.shared.alwaysLoadedSpecs(mode: mode)
        }
    }
    func listEnabledTools() async -> [ToolListEntry] {
        await MainActor.run {
            ToolRegistry.shared.listTools().filter { $0.enabled }.map {
                ToolListEntry(name: $0.name, description: $0.description, parameters: $0.parameters)
            }
        }
    }
    func parameters(forTool name: String) async -> JSONValue? {
        await MainActor.run { ToolRegistry.shared.parametersForTool(name: name) }
    }
    func execute(name: String, argumentsJSON: String) async throws -> String {
        try await ToolRegistry.shared.execute(name: name, argumentsJSON: argumentsJSON)
    }
}

struct AppMemoryProvider: MemoryProvider {
    var isOpen: Bool { MemoryDatabase.shared.isOpen }
    func deleteTranscriptForConversation(_ conversationId: String) throws {
        try MemoryDatabase.shared.deleteTranscriptForConversation(conversationId)
    }
    func insertTranscriptTurn(
        agentId: String, conversationId: String, chunkIndex: Int,
        role: String, content: String, tokenCount: Int, createdAt: String?
    ) throws {
        try MemoryDatabase.shared.insertTranscriptTurn(
            agentId: agentId, conversationId: conversationId, chunkIndex: chunkIndex,
            role: role, content: content, tokenCount: tokenCount, createdAt: createdAt
        )
    }
    func agentIdsWithPinnedFacts() throws -> [(agentId: String, count: Int)] {
        try MemoryDatabase.shared.agentIdsWithPinnedFacts()
    }
}

struct AppTunnelResolver: TunnelResolver {
    func tunnelBaseURL(for agentId: UUID) async -> String? {
        await MainActor.run {
            if case .connected(let url) = RelayTunnelManager.shared.agentStatuses[agentId] {
                return url
            }
            return nil
        }
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
