import Foundation

/// Process-wide registry of host-supplied engine seams. CLI keeps the
/// no-op defaults; Mac app registers real adapters at startup.
public enum InferenceServices {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _progressReporter: any ProgressReporter
        = NoOpProgressReporter()

    public static var progressReporter: any ProgressReporter {
        lock.withLock { _progressReporter }
    }

    public static func register(progressReporter: any ProgressReporter) {
        lock.withLock { _progressReporter = progressReporter }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
