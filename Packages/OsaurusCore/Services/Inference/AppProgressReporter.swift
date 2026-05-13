import Foundation

/// Bridges the engine's `ProgressReporter` seam to the SwiftUI
/// `InferenceProgressManager` singleton. Registered in `AppDelegate`.
public struct AppProgressReporter: ProgressReporter {
    public init() {}

    public func modelLoadWillStart() {
        InferenceProgressManager.shared.modelLoadWillStartAsync()
    }

    public func modelLoadDidFinish() {
        InferenceProgressManager.shared.modelLoadDidFinishAsync()
    }

    public func prefillWillStart(tokenCount: Int) {
        InferenceProgressManager.shared.prefillWillStartAsync(tokenCount: tokenCount)
    }

    public func prefillDidFinish() {
        InferenceProgressManager.shared.prefillDidFinishAsync()
    }
}
