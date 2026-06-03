//
//  TTSModelDownloadDialog.swift
//  osaurus
//
//  Inline progress dialog shown when the user taps the speaker (or auto-speak
//  fires) but the PocketTTS model isn't ready yet. The download/upgrade starts
//  automatically; this dialog just surfaces progress, is dismissible, and —
//  because it reads `TTSService.modelState` live — shows current progress
//  rather than re-prompting when reopened.
//

import SwiftUI

/// Live progress body rendered as the `customContent` of a themed alert.
/// Observes `TTSService` so the status line and progress bar track
/// `modelState` in real time, and auto-closes shortly after the model is ready.
struct TTSModelDownloadContent: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var tts = TTSService.shared

    /// What the in-flight download will do (migration vs fresh, size). Captured
    /// at present time for the copy; the live state still comes from `tts`.
    let plan: TTSService.TTSDownloadPlan
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusRow
            progressBar
            captionText
            if case .failed = tts.modelState {
                retryButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .onChange(of: isReady) { _, ready in
            // Let the "ready" state read for a beat, then dismiss.
            if ready {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { onClose() }
            }
        }
    }

    private var isReady: Bool {
        if case .ready = tts.modelState { return true }
        return false
    }

    // MARK: - Status row

    private var statusRow: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(LocalizedStringKey(statusText), bundle: .module)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
            Spacer(minLength: 8)
            if case .downloading(let fraction) = tts.modelState, let fraction {
                Text(String(format: "%d%%", Int(fraction * 100)))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch tts.modelState {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.successColor)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.errorColor)
        case .downloading, .notReady:
            ProgressView().controlSize(.small)
        }
    }

    private var statusText: String {
        switch tts.modelState {
        case .ready:
            return "Voice model ready"
        case .failed:
            return "Download failed"
        case .downloading, .notReady:
            return plan.isUpgrade ? "Updating the voice model…" : "Downloading the voice model…"
        }
    }

    // MARK: - Progress bar

    @ViewBuilder private var progressBar: some View {
        switch tts.modelState {
        case .downloading(let fraction):
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(theme.accentColor)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(theme.accentColor)
            }
        case .notReady:
            ProgressView()
                .progressViewStyle(.linear)
                .tint(theme.accentColor)
        case .ready, .failed:
            EmptyView()
        }
    }

    // MARK: - Caption

    private var captionText: some View {
        Text(LocalizedStringKey(caption), bundle: .module)
            .font(.system(size: 11))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var caption: String {
        if case .failed(let message) = tts.modelState {
            return message
        }
        let languageNote = "Other languages can be added in Voice settings."
        if let size = plan.sizeText {
            return "\(size), one-time download. \(languageNote)"
        }
        return "One-time download. \(languageNote)"
    }

    // MARK: - Retry

    private var retryButton: some View {
        Button(action: { TTSService.shared.ensureModelLoaded() }) {
            Text("Try Again", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.isDark ? theme.primaryBackground : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accentColor)
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// Presents the inline TTS download dialog through the per-window themed-alert
/// center. Safe to call repeatedly — reopening shows the live download state
/// instead of re-prompting.
enum TTSDownloadPrompt {
    @MainActor
    static func present(scope: ThemedAlertScope) {
        // Nothing to show once the model is ready.
        if TTSService.shared.isModelReady { return }

        let plan = TTSService.plannedDownload()
        let id = UUID()
        let dismiss: () -> Void = { ThemedAlertCenter.shared.dismiss(scope: scope, id: id) }

        let title = plan.isUpgrade ? "Updating Text-to-Speech Model" : "Downloading Text-to-Speech Model"
        let request = ThemedAlertRequest(
            id: id,
            title: title,
            message: nil,
            buttons: [.cancel("Close")],
            showsCloseButton: true,
            customContent: AnyView(TTSModelDownloadContent(plan: plan, onClose: dismiss)),
            width: 360,
            onDismiss: dismiss
        )
        ThemedAlertCenter.shared.present(request, scope: scope)
    }
}
