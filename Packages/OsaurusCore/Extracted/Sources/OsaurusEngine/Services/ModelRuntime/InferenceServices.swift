import Foundation

/// Process-wide registry of host-supplied engine seams. CLI keeps the
/// defaults; Mac app registers real adapters at startup.
enum InferenceServices {
    private static let lock = NSLock()

    nonisolated(unsafe) private static var _progressReporter: any ProgressReporter
        = NoOpProgressReporter()
    nonisolated(unsafe) private static var _serverConfig: any ServerConfigurationProvider
        = DefaultServerConfigurationProvider()
    nonisolated(unsafe) private static var _modelDirectory: any ModelDirectoryProvider
        = DefaultModelDirectoryProvider()
    nonisolated(unsafe) private static var _downloadVerifier: any DownloadVerifier
        = NoOpDownloadVerifier()
    nonisolated(unsafe) private static var _modelLocator: any ModelLocator
        = NoOpModelLocator()
    nonisolated(unsafe) private static var _modelList: any ModelListProvider
        = NoOpModelListProvider()
    nonisolated(unsafe) private static var _telemetry: any Telemetry
        = NoOpTelemetry()
    nonisolated(unsafe) private static var _tunnelResolver: any TunnelResolver
        = NoOpTunnelResolver()
    nonisolated(unsafe) private static var _memory: any MemoryProvider
        = NoOpMemoryProvider()
    nonisolated(unsafe) private static var _tools: any ToolExecutor
        = NoOpToolExecutor()
    nonisolated(unsafe) private static var _agents: any AgentProvider
        = NoOpAgentProvider()
    nonisolated(unsafe) private static var _agentEnricher: any AgentEnricher
        = NoOpAgentEnricher()
    nonisolated(unsafe) private static var _chatHistory: any ChatHistoryPersister
        = NoOpChatHistoryPersister()
    nonisolated(unsafe) private static var _embedding: any EmbeddingProvider
        = NoOpEmbeddingProvider()
    nonisolated(unsafe) private static var _speech: any SpeechProvider
        = NoOpSpeechProvider()
    nonisolated(unsafe) private static var _backgroundTasks: any BackgroundTaskService
        = NoOpBackgroundTaskService()
    nonisolated(unsafe) private static var _chatEngine: any ChatEngineProvider
        = NoOpChatEngineProvider()

    static var progressReporter: any ProgressReporter {
        lock.withLock { _progressReporter }
    }
    static var serverConfig: any ServerConfigurationProvider {
        lock.withLock { _serverConfig }
    }
    static var modelDirectory: any ModelDirectoryProvider {
        lock.withLock { _modelDirectory }
    }
    static var downloadVerifier: any DownloadVerifier {
        lock.withLock { _downloadVerifier }
    }
    static var modelLocator: any ModelLocator {
        lock.withLock { _modelLocator }
    }
    static var modelList: any ModelListProvider {
        lock.withLock { _modelList }
    }
    static var telemetry: any Telemetry {
        lock.withLock { _telemetry }
    }
    static var tunnelResolver: any TunnelResolver {
        lock.withLock { _tunnelResolver }
    }
    static var memory: any MemoryProvider {
        lock.withLock { _memory }
    }
    static var tools: any ToolExecutor {
        lock.withLock { _tools }
    }
    static var agents: any AgentProvider {
        lock.withLock { _agents }
    }
    static var agentEnricher: any AgentEnricher {
        lock.withLock { _agentEnricher }
    }
    static var chatHistory: any ChatHistoryPersister {
        lock.withLock { _chatHistory }
    }
    static var embedding: any EmbeddingProvider {
        lock.withLock { _embedding }
    }
    static var speech: any SpeechProvider {
        lock.withLock { _speech }
    }
    static var backgroundTasks: any BackgroundTaskService {
        lock.withLock { _backgroundTasks }
    }
    static var chatEngine: any ChatEngineProvider {
        lock.withLock { _chatEngine }
    }

    static func register(progressReporter: any ProgressReporter) {
        lock.withLock { _progressReporter = progressReporter }
    }
    static func register(serverConfig: any ServerConfigurationProvider) {
        lock.withLock { _serverConfig = serverConfig }
    }
    static func register(modelDirectory: any ModelDirectoryProvider) {
        lock.withLock { _modelDirectory = modelDirectory }
    }
    static func register(downloadVerifier: any DownloadVerifier) {
        lock.withLock { _downloadVerifier = downloadVerifier }
    }
    static func register(modelLocator: any ModelLocator) {
        lock.withLock { _modelLocator = modelLocator }
    }
    static func register(modelList: any ModelListProvider) {
        lock.withLock { _modelList = modelList }
    }
    static func register(telemetry: any Telemetry) {
        lock.withLock { _telemetry = telemetry }
    }
    static func register(tunnelResolver: any TunnelResolver) {
        lock.withLock { _tunnelResolver = tunnelResolver }
    }
    static func register(memory: any MemoryProvider) {
        lock.withLock { _memory = memory }
    }
    static func register(tools: any ToolExecutor) {
        lock.withLock { _tools = tools }
    }
    static func register(agents: any AgentProvider) {
        lock.withLock { _agents = agents }
    }
    static func register(agentEnricher: any AgentEnricher) {
        lock.withLock { _agentEnricher = agentEnricher }
    }
    static func register(chatHistory: any ChatHistoryPersister) {
        lock.withLock { _chatHistory = chatHistory }
    }
    static func register(embedding: any EmbeddingProvider) {
        lock.withLock { _embedding = embedding }
    }
    static func register(speech: any SpeechProvider) {
        lock.withLock { _speech = speech }
    }
    static func register(backgroundTasks: any BackgroundTaskService) {
        lock.withLock { _backgroundTasks = backgroundTasks }
    }
    static func register(chatEngine: any ChatEngineProvider) {
        lock.withLock { _chatEngine = chatEngine }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
