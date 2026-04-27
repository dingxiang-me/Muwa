//
//  OnboardingWelcomeView.swift
//  osaurus
//
//  Two-column welcome screen: text/CTA on the left, hero image on the right.
//

import SwiftUI

// MARK: - Animation Phase

private enum WelcomePhase: Int {
    case initial = 0
    case logo = 1
    case headline = 2
    case body = 3
    case button = 4
}

// MARK: - Welcome View

struct OnboardingWelcomeView: View {
    let onContinue: () -> Void

    @Environment(\.theme) private var theme
    @State private var phase: WelcomePhase = .initial

    private var logoVisible: Bool    { phase.rawValue >= WelcomePhase.logo.rawValue }
    private var headlineVisible: Bool { phase.rawValue >= WelcomePhase.headline.rawValue }
    private var bodyVisible: Bool    { phase.rawValue >= WelcomePhase.body.rawValue }
    private var buttonVisible: Bool  { phase.rawValue >= WelcomePhase.button.rawValue }

    var body: some View {
        HStack(spacing: 0) {
            rightColumn
            leftColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            guard phase != .button else { return }
            withAnimation(.easeOut(duration: 0.35)) { phase = .button }
        }
        .task { await runAnimationSequence() }
    }

    // MARK: - Left Column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            // Logo wordmark — rendered as template so it adopts primaryText colour
            // (cream on dark, dark-navy on light), making it legible on any background.
            Image("osaurus-logo-wordmark", bundle: .module)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 30)
                .foregroundColor(theme.primaryText)
                .opacity(logoVisible ? 1 : 0)
                .offset(y: logoVisible ? 0 : 8)
                .animation(.easeOut(duration: 0.5), value: logoVisible)

            Spacer().frame(height: 24)

            // Headline
            Text("Own your AI.", bundle: .module)
                .font(theme.font(size: 34, weight: .bold))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(headlineVisible ? 1 : 0)
                .offset(y: headlineVisible ? 0 : 14)
                .animation(.easeOut(duration: 0.5), value: headlineVisible)

            Spacer().frame(height: 12)

            // Subtitle
            Text(
                "Agents, memory, tools, and identity that live on your Mac. Models are interchangeable — everything else compounds, stays with you.",
                bundle: .module
            )
            .font(theme.font(size: 14))
            .foregroundColor(theme.secondaryText)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(bodyVisible ? 1 : 0)
            .offset(y: bodyVisible ? 0 : 10)
            .animation(.easeOut(duration: 0.5), value: bodyVisible)

            Spacer().frame(height: 28)

            // CTA
            OnboardingBrandButton(title: "Get Started", action: onContinue)
                .frame(width: OnboardingMetrics.ctaWidthCompact)
                .opacity(buttonVisible ? 1 : 0)
                .scaleEffect(buttonVisible ? 1 : 0.95)
                .animation(theme.springAnimation(), value: buttonVisible)

            Spacer()
        }
        .padding(.leading, OnboardingMetrics.contentHorizontal)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Right Column

    private var rightColumn: some View {
        Image("osaurus-onboarding-welcome", bundle: .module)
            .resizable()
            .scaledToFit()
            // Constrain height so the image never overflows the window.
            // Width is driven by the HStack's equal split (~370 pt).
            .frame(maxWidth: .infinity, maxHeight: 340)
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(logoVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.8), value: logoVisible)
    }

    // MARK: - Animation

    /// Reveal the logo, then the headline, body and CTA in a tight cadence.
    private func runAnimationSequence() async {
        let cadence: [(phase: WelcomePhase, delay: UInt64)] = [
            (.logo,     250_000_000),
            (.headline, 650_000_000),
            (.body,     350_000_000),
            (.button,   350_000_000),
        ]
        for step in cadence {
            try? await Task.sleep(nanoseconds: step.delay)
            guard !Task.isCancelled else { return }
            phase = step.phase
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingWelcomeView_Previews: PreviewProvider {
        static var previews: some View {
            OnboardingWelcomeView(onContinue: {})
                .frame(width: 740, height: 480)
        }
    }
#endif
