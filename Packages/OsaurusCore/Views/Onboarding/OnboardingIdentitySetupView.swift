//
//  OnboardingIdentitySetupView.swift
//  osaurus
//
//  Onboarding step 4 — create a cryptographic identity. Three internal
//  phases (prompt → generating → recovery code) swap inside the body slot
//  so the chrome stays still.
//
//  Split into State + Body + CTA so the chrome shell can sit at the
//  parent level.
//

import AppKit
import SwiftUI

// MARK: - Phase

enum OnboardingIdentityPhase: Equatable {
    case prompt
    case generating
    case recovery(IdentityInfo)
    case error(String)

    static func == (lhs: OnboardingIdentityPhase, rhs: OnboardingIdentityPhase) -> Bool {
        switch (lhs, rhs) {
        case (.prompt, .prompt): return true
        case (.generating, .generating): return true
        case (.recovery(let a), .recovery(let b)): return a.osaurusId == b.osaurusId
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - State

@MainActor
final class IdentityState: ObservableObject {
    @Published var phase: OnboardingIdentityPhase = .prompt

    /// A footer caption that nudges the user about the recovery code rules
    /// only on the recovery phase. Other phases hide it.
    var footerCaption: LocalizedStringKey? {
        switch phase {
        case .recovery:
            return "Your recovery code is shown once. Copy it before you continue."
        case .prompt, .generating, .error:
            return nil
        }
    }

    func generate() {
        phase = .generating
        // No `withAnimation` wrappers below — the body has its own
        // `.animation(value: phaseID)` modifier scoped to the phase ZStack.
        // Wrapping here would propagate to the CTA (which observes `phase`)
        // and morph the button between phases.
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let info = try await OsaurusIdentity.setup()
                self.phase = .recovery(info)
            } catch {
                self.phase = .error(error.localizedDescription)
            }
        }
    }
}

// MARK: - Body

struct IdentityBody: View {
    @ObservedObject var state: IdentityState

    @Environment(\.theme) private var theme

    var body: some View {
        OnboardingTwoColumnBody(
            illustrationAsset: "osaurus-identity",
            leftHeadline: leftHeadline,
            leftBody: leftBody,
            subtitle: subtitle
        ) {
            ZStack {
                phaseBody
                    .id(phaseID)
                    .transition(phaseTransition)
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: phaseID)
        }
    }

    // MARK: - Copy

    private var leftHeadline: LocalizedStringKey {
        switch state.phase {
        case .prompt, .generating, .error: return "Claim your identity"
        case .recovery: return "Save this somewhere safe"
        }
    }

    private var leftBody: LocalizedStringKey {
        switch state.phase {
        case .prompt, .error:
            return
                "A private key that signs your agents and lets you reach them across devices. Stored securely in iCloud Keychain."
        case .generating:
            return "Generating a fresh keypair. This only takes a moment."
        case .recovery:
            return
                "Your recovery code is the one way to restore this identity if you lose access. Lost codes can't be recovered — not even by Osaurus."
        }
    }

    private var subtitle: LocalizedStringKey {
        switch state.phase {
        case .prompt, .error: return "Sign messages and pair across your devices."
        case .generating: return "Creating your keypair…"
        case .recovery: return "Shown once. Copy it before you continue."
        }
    }

    private var phaseID: String {
        switch state.phase {
        case .prompt: return "prompt"
        case .generating: return "generating"
        case .recovery: return "recovery"
        case .error: return "error"
        }
    }

    private var phaseTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 24)),
            removal: .opacity.combined(with: .offset(x: -24))
        )
    }

    // MARK: - Phase body

    @ViewBuilder
    private var phaseBody: some View {
        switch state.phase {
        case .prompt:
            promptBody
        case .generating:
            generatingBody
        case .recovery(let info):
            recoveryBody(info: info)
        case .error(let message):
            VStack(alignment: .leading, spacing: 12) {
                errorBanner(message)
                promptBody
            }
        }
    }

    private var promptBody: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                bulletRow(
                    icon: "checkmark.shield.fill",
                    title: L("Signs every message your agents send"),
                    detail: L("Recipients can verify it really came from you.")
                )
                bulletRow(
                    icon: "icloud.fill",
                    title: L("Synced across your devices"),
                    detail: L("Stored in iCloud Keychain — never in plain text.")
                )
                bulletRow(
                    icon: "hand.raised.fill",
                    title: L("Skippable, addable later"),
                    detail: L("You can come back from Settings any time.")
                )
            }
            .padding(14)
        }
    }

    private func bulletRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(detail)
                    .font(theme.font(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.errorColor)
            Text(message)
                .font(theme.font(size: 12, weight: .medium))
                .foregroundColor(theme.errorColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.errorColor.opacity(0.10))
        )
    }

    private var generatingBody: some View {
        HStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.9)
            Text("Generating identity…", bundle: .module)
                .font(theme.font(size: 13, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: OnboardingMetrics.cardCornerRadius, style: .continuous)
                .fill(theme.cardBackground.opacity(theme.glassEnabled ? 0.5 : 1.0))
                .overlay(
                    RoundedRectangle(cornerRadius: OnboardingMetrics.cardCornerRadius, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func recoveryBody(info: IdentityInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Text("Lost codes cannot be recovered.", bundle: .module)
                    .font(theme.font(size: 12, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.warningColor.opacity(0.10))
            )

            OnboardingGlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("RECOVERY CODE", bundle: .module)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .tracking(1)

                    Text(info.recovery.code)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .textSelection(.enabled)

                    Divider().background(theme.secondaryBorder)

                    HStack(spacing: 6) {
                        Text("Master Address", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                        Text(info.osaurusId)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }
}

// MARK: - CTA

struct IdentityCTA: View {
    @ObservedObject var state: IdentityState
    let onComplete: () -> Void

    var body: some View {
        switch state.phase {
        case .prompt, .error:
            OnboardingBrandButton(title: "Create Identity", action: state.generate)
                .frame(width: OnboardingMetrics.ctaWidthCompact)

        case .generating:
            // Reserve the CTA footprint so the action row doesn't twitch
            // when the phase advances.
            Color.clear.frame(width: OnboardingMetrics.ctaWidthCompact, height: OnboardingMetrics.buttonHeight)

        case .recovery:
            OnboardingBrandButton(title: "I've Saved It", action: onComplete)
                .frame(width: OnboardingMetrics.ctaWidthCompact)
        }
    }
}

// MARK: - Secondary

struct IdentitySecondary: View {
    @ObservedObject var state: IdentityState
    let onSkip: () -> Void

    var body: some View {
        switch state.phase {
        case .prompt, .error:
            OnboardingTextButton(title: "Skip for now", action: onSkip)
        case .generating:
            EmptyView()
        case .recovery(let info):
            OnboardingTextButton(title: "Copy code") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info.recovery.code, forType: .string)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingIdentitySetupView_Previews: PreviewProvider {
        static var previews: some View {
            let state = IdentityState()
            return VStack {
                IdentityBody(state: state).frame(height: 460)
                HStack {
                    IdentitySecondary(state: state, onSkip: {})
                    Spacer()
                    IdentityCTA(state: state, onComplete: {})
                }
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 640)
        }
    }
#endif
