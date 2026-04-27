//
//  OnboardingChoosePathView.swift
//  osaurus
//
//  Path selection view: Local Model vs API Provider.
//  Features glass cards with gradient borders and hover effects.
//

import SwiftUI

/// Setup path options
enum OnboardingSetupPath: String, CaseIterable {
    case appleFoundation
    case local
    case apiProvider

    var title: String {
        switch self {
        case .appleFoundation: return L("Apple Intelligence")
        case .local: return L("Local model")
        case .apiProvider: return L("AI provider")
        }
    }

    var description: String {
        switch self {
        case .appleFoundation: return L("Already on your Mac. Private, instant, no setup.")
        case .local: return L("Download once, runs forever on-device. No account needed.")
        case .apiProvider: return L("ChatGPT, Claude, Gemini, and more. Requires an API key.")
        }
    }

    var icon: String {
        switch self {
        case .appleFoundation: return "apple.logo"
        case .local: return "internaldrive"
        case .apiProvider: return "network"
        }
    }
}

struct OnboardingChoosePathView: View {
    let onSelectLocal: () -> Void
    let onSelectAPI: () -> Void
    let onSelectFoundation: () -> Void

    @Environment(\.theme) private var theme
    @State private var selectedPath: OnboardingSetupPath? = nil
    @State private var hasAppeared = false

    private let foundationAvailable = FoundationModelService.isDefaultModelAvailable()

    private var orderedPaths: [OnboardingSetupPath] {
        if foundationAvailable {
            return [.appleFoundation, .local, .apiProvider]
        } else {
            return [.local, .apiProvider]
        }
    }

    private var footerCaption: LocalizedStringKey {
        if foundationAvailable {
            return "You can add more providers any time in Settings."
        } else {
            return "You can add more providers any time in Settings."
        }
    }

    var body: some View {
        OnboardingScaffold(
            title: "How do you want to run Osaurus?",
            footer: footerCaption,
            content: {
                VStack(spacing: OnboardingMetrics.cardSpacing) {
                    ForEach(Array(orderedPaths.enumerated()), id: \.element) { index, path in
                        OnboardingRowCard(
                            icon: .symbol(path.icon),
                            title: path.title,
                            subtitle: path.description,
                            accessory: .radio(isSelected: selectedPath == path),
                            isSelected: selectedPath == path
                        ) {
                            withAnimation(theme.animationQuick()) {
                                selectedPath = path
                            }
                        }
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 12)
                        .animation(
                            theme.springAnimation().delay(0.12 + Double(index) * 0.06),
                            value: hasAppeared
                        )
                    }
                }
            },
            cta: {
                OnboardingBrandButton(
                    title: "Continue",
                    action: continueAction,
                    isEnabled: selectedPath != nil
                )
                .frame(width: OnboardingMetrics.ctaWidthCompact)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 15)
                .animation(theme.springAnimation().delay(foundationAvailable ? 0.45 : 0.38), value: hasAppeared)
            }
        )
        .onAppear {
            // Default select Apple Foundation if available
            if foundationAvailable {
                selectedPath = .appleFoundation
            }
        }
        .onAppearAfter(OnboardingMetrics.appearDelay) {
            withAnimation { hasAppeared = true }
        }
    }

    private func continueAction() {
        switch selectedPath {
        case .appleFoundation:
            onSelectFoundation()
        case .local:
            onSelectLocal()
        case .apiProvider:
            onSelectAPI()
        case .none:
            break
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingChoosePathView_Previews: PreviewProvider {
        static var previews: some View {
            OnboardingChoosePathView(
                onSelectLocal: {},
                onSelectAPI: {},
                onSelectFoundation: {}
            )
            .frame(width: OnboardingMetrics.windowWidth, height: 620)
        }
    }
#endif
