import Foundation

/// Bridges the engine's `ProgressReporter` seam to the SwiftUI
/// `InferenceProgressManager` singleton. Registered in `AppDelegate`.
struct AppProgressReporter: ProgressReporter {
    func modelLoadWillStart() {
        InferenceProgressManager.shared.modelLoadWillStartAsync()
    }

    func modelLoadDidFinish() {
        InferenceProgressManager.shared.modelLoadDidFinishAsync()
    }

    func prefillWillStart(tokenCount: Int) {
        InferenceProgressManager.shared.prefillWillStartAsync(tokenCount: tokenCount)
    }

    func prefillDidFinish() {
        InferenceProgressManager.shared.prefillDidFinishAsync()
    }
}
