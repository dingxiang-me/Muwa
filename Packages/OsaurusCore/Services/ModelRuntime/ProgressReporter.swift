import Foundation

/// Host-supplied progress signal. Fire-and-forget — implementations must
/// be non-blocking; hop to MainActor internally if needed.
protocol ProgressReporter: Sendable {
    /// Pair with exactly one `modelLoadDidFinish()` on every exit path.
    /// Refcount-friendly: concurrent loads from multiple windows must not
    /// corrupt each other.
    func modelLoadWillStart()
    func modelLoadDidFinish()

    /// Pass `0` when the count isn't known yet; the engine fires this
    /// twice (pre-tokenization, then with the real count).
    func prefillWillStart(tokenCount: Int)
    func prefillDidFinish()
}

struct NoOpProgressReporter: ProgressReporter {
    func modelLoadWillStart() {}
    func modelLoadDidFinish() {}
    func prefillWillStart(tokenCount: Int) {}
    func prefillDidFinish() {}
}
