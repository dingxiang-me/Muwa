//
//  OnboardingCompleteView.swift
//  osaurus
//
//  Setup complete view: branded success mark + next-step options.
//

import SwiftUI

struct OnboardingCompleteView: View {
    let onWalkthrough: () -> Void
    let onSkip: () -> Void
    let onSettings: () -> Void

    @Environment(\.theme) private var theme
    @State private var hasAppeared = false

    var body: some View {
        OnboardingScaffold(
            title: "You're all set",
            subtitle: "Osaurus is ready. What would you like to do next?",
            content: {
                VStack(spacing: 0) {
                    // Success mark
                    ZStack {
                        Circle()
                            .fill(theme.successColor.opacity(0.15))
                            .frame(width: 76, height: 76)
                            .blur(radius: 18)

                        Circle()
                            .fill(theme.successColor.opacity(0.1))
                            .frame(width: 60, height: 60)

                        Image(systemName: "checkmark")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(theme.successColor)
                    }
                    .opacity(hasAppeared ? 1 : 0)
                    .scaleEffect(hasAppeared ? 1 : 0.5)
                    .animation(theme.springAnimation().delay(0.05), value: hasAppeared)

                    Spacer().frame(height: 24)

                    VStack(spacing: OnboardingMetrics.cardSpacing) {
                        OnboardingRowCard(
                            icon: .symbol("sparkles"),
                            title: "Take a quick tour",
                            subtitle: "See what Osaurus can do in 2 minutes",
                            accessory: .chevron,
                            action: onWalkthrough
                        )
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(theme.springAnimation().delay(0.18), value: hasAppeared)

                        OnboardingRowCard(
                            icon: .symbol("slider.horizontal.3"),
                            title: "Set up Osaurus",
                            subtitle: "Providers, permissions, and appearance",
                            accessory: .chevron,
                            action: onSettings
                        )
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(theme.springAnimation().delay(0.23), value: hasAppeared)

                        OnboardingRowCard(
                            icon: .symbol("bubble.left.and.bubble.right"),
                            title: "Start chatting",
                            subtitle: "Jump straight in",
                            accessory: .chevron,
                            action: onSkip
                        )
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(theme.springAnimation().delay(0.28), value: hasAppeared)
                    }
                }
            }
        )
        .onAppearAfter(OnboardingMetrics.appearDelay) { hasAppeared = true }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingCompleteView_Previews: PreviewProvider {
        static var previews: some View {
            OnboardingCompleteView(
                onWalkthrough: {},
                onSkip: {},
                onSettings: {}
            )
            .frame(width: OnboardingMetrics.windowWidth, height: 600)
        }
    }
#endif
