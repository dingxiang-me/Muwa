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

struct AppAgentEnricher: AgentEnricher {
    func enrich(_ request: ChatCompletionRequest, agentId: String) async -> ChatCompletionRequest {
        guard let agentUUID = UUID(uuidString: agentId) else { return request }
        var enriched = request
        let query = request.messages.last(where: { $0.role == "user" })?.content ?? ""
        let composed = await SystemPromptComposer.composeChatContext(
            agentId: agentUUID,
            executionMode: .none,
            query: query,
            messages: enriched.messages
        )
        if !composed.prompt.isEmpty {
            SystemPromptComposer.injectSystemContent(composed.prompt, into: &enriched.messages)
        }
        SystemPromptComposer.injectMemoryPrefix(composed.memorySection, into: &enriched.messages)
        return enriched
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

    /// Catches app-specific errors (FolderToolError, ToolRegistry NSError
    /// permission codes) and returns rich envelope JSON inline so the
    /// engine's generic fallback never sees them.
    func execute(name: String, argumentsJSON: String) async throws -> String {
        do {
            return try await ToolRegistry.shared.execute(name: name, argumentsJSON: argumentsJSON)
        } catch let folderErr as FolderToolError {
            return Self.envelope(for: folderErr, tool: name)
        } catch let nserr as NSError where nserr.domain == "ToolRegistry" {
            if let env = Self.envelope(forToolRegistryNSError: nserr, tool: name) { return env }
            throw nserr
        }
    }

    private static func envelope(for folderErr: FolderToolError, tool: String) -> String {
        switch folderErr {
        case .invalidArguments(let msg):
            return ToolEnvelope.failure(kind: .invalidArgs, message: msg, tool: tool)
        case .pathOutsideRoot(let path):
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Path '\(path)' is outside the working directory. "
                    + "Use a relative path under the working folder, e.g. `src/app.py`.",
                field: "path",
                expected: "relative path under the working folder",
                tool: tool
            )
        case .fileNotFound(let path):
            return ToolEnvelope.failure(
                kind: .executionError, message: "File not found: \(path)",
                tool: tool, retryable: false
            )
        case .directoryNotFound(let path):
            return ToolEnvelope.failure(
                kind: .executionError, message: "Directory not found: \(path)",
                tool: tool, retryable: false
            )
        case .operationFailed(let msg):
            return ToolEnvelope.failure(kind: .executionError, message: msg, tool: tool)
        }
    }

    private static func envelope(forToolRegistryNSError nserr: NSError, tool: String) -> String? {
        switch nserr.code {
        case 4:  // user denied via interactive approval
            return ToolEnvelope.failure(
                kind: .userDenied, message: nserr.localizedDescription,
                tool: tool, retryable: false
            )
        case 3, 6:  // policy deny
            return ToolEnvelope.failure(
                kind: .rejected, message: nserr.localizedDescription,
                tool: tool, retryable: false
            )
        case 7:  // missing system permissions
            return ToolEnvelope.failure(
                kind: .unavailable, message: nserr.localizedDescription,
                tool: tool, retryable: false
            )
        default:
            return nil
        }
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

struct AppChatHistoryPersister: ChatHistoryPersister {
    func persist(
        sourceTag: String,
        sourcePluginId: String?,
        agentId: UUID?,
        externalKey: String?,
        finalMessages: [ChatMessage],
        model: String
    ) async {
        let source: SessionSource =
            sourceTag == "plugin" ? .plugin : .http
        ChatHistoryWriter.persist(
            source: source,
            sourcePluginId: sourcePluginId,
            agentId: agentId,
            externalKey: externalKey,
            finalMessages: finalMessages,
            model: model
        )
    }
}

struct AppEmbeddingProvider: EmbeddingProvider {
    var modelName: String { EmbeddingService.modelName }
    func embed(texts: [String]) async throws -> [[Float]] {
        try await EmbeddingService.shared.embed(texts: texts)
    }
}

struct AppSpeechProvider: SpeechProvider {
    func transcribe(audioURL: URL) async throws -> (text: String, durationSeconds: TimeInterval?) {
        let service = await MainActor.run { SpeechService.shared }
        let result = try await service.transcribe(audioURL: audioURL)
        return (text: result.text, durationSeconds: result.durationSeconds)
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
