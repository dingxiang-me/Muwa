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
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
