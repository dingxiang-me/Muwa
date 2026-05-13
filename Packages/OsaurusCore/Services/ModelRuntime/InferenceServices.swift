import Foundation

/// Process-wide registry of host-supplied engine seams. CLI keeps the
/// defaults; Mac app registers real adapters at startup.
public enum InferenceServices {
    private static let lock = NSLock()

    nonisolated(unsafe) private static var _progressReporter: any ProgressReporter
        = NoOpProgressReporter()
    nonisolated(unsafe) private static var _serverConfig: any ServerConfigurationProvider
        = DefaultServerConfigurationProvider()
    nonisolated(unsafe) private static var _modelDirectory: any ModelDirectoryProvider
        = DefaultModelDirectoryProvider()
    nonisolated(unsafe) private static var _downloadVerifier: any DownloadVerifier
        = NoOpDownloadVerifier()

    public static var progressReporter: any ProgressReporter {
        lock.withLock { _progressReporter }
    }
    public static var serverConfig: any ServerConfigurationProvider {
        lock.withLock { _serverConfig }
    }
    public static var modelDirectory: any ModelDirectoryProvider {
        lock.withLock { _modelDirectory }
    }
    public static var downloadVerifier: any DownloadVerifier {
        lock.withLock { _downloadVerifier }
    }

    public static func register(progressReporter: any ProgressReporter) {
        lock.withLock { _progressReporter = progressReporter }
    }
    public static func register(serverConfig: any ServerConfigurationProvider) {
        lock.withLock { _serverConfig = serverConfig }
    }
    public static func register(modelDirectory: any ModelDirectoryProvider) {
        lock.withLock { _modelDirectory = modelDirectory }
    }
    public static func register(downloadVerifier: any DownloadVerifier) {
        lock.withLock { _downloadVerifier = downloadVerifier }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
