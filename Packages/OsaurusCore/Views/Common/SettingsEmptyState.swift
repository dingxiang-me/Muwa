//
//  SettingsEmptyState.swift
//  osaurus
//
//  Unified empty state component for settings tabs (Watchers, Schedules, Skills, Agents).
//  Displays a glowing icon, title, subtitle, example cards, and action buttons.
//

import SwiftUI

// MARK: - Models

extension SettingsEmptyState {
    struct Example {
        let icon: String
        let title: String
        let description: String
    }

    struct Action {
        let title: String
        let icon: String
        let handler: () -> Void
    }
}

// MARK: - Settings Empty State

struct SettingsEmptyState: View {
    @Environment(\.theme) private var theme

    let icon: String
    let title: String
    let subtitle: String
    let examples: [Example]
    let primaryAction: Action
    var secondaryAction: Action? = nil
    let hasAppeared: Bool

    @State private var glowIntensity: CGFloat = 0.6

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            glowingIcon
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.8)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1), value: hasAppeared)

            VStack(spacing: 8) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text(LocalizedStringKey(subtitle), bundle: .module)
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 15)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: hasAppeared)

            if !examples.isEmpty {
                exampleCards
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: hasAppeared)
            }

            actionButtons
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 10)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.4), value: hasAppeared)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                glowIntensity = 1.0
            }
        }
    }

    // MARK: - Glowing Icon

    private var glowingIcon: some View {
        ZStack {
            Circle()
                .fill(theme.accentColor)
                .frame(width: 88, height: 88)
                .blur(radius: 25)
                .opacity(glowIntensity * 0.25)

            Circle()
                .fill(theme.accentColor)
                .frame(width: 88, height: 88)
                .blur(radius: 12)
                .opacity(glowIntensity * 0.15)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [theme.accentColor.opacity(0.15), theme.accentColor.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 88, height: 88)

            Image(systemName: icon)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [theme.accentColor, theme.accentColor.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    // MARK: - Example Cards

    private var exampleCards: some View {
        // `fixedSize` + `maxHeight: .infinity` equalizes card heights to
        // the tallest sibling so uneven copy lengths don't produce a
        // ragged row.
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(examples.enumerated()), id: \.offset) { _, example in
                VStack(spacing: 10) {
                    Image(systemName: example.icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [theme.accentColor, theme.accentColor.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(theme.accentColor.opacity(0.1))
                                .overlay(
                                    Circle().stroke(theme.accentColor.opacity(0.15), lineWidth: 1)
                                )
                        )

                    VStack(spacing: 4) {
                        Text(example.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(example.description)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 14)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.secondaryBackground.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(theme.cardBorder.opacity(0.5), lineWidth: 1)
                        )
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 560)
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 12) {
            if let secondary = secondaryAction {
                Button(action: secondary.handler) {
                    Label(secondary.title, systemImage: secondary.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.tertiaryBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }

            Button(action: primaryAction.handler) {
                Label(primaryAction.title, systemImage: primaryAction.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor)
                            .shadow(color: theme.accentColor.opacity(0.35), radius: 8, x: 0, y: 3)
                    )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}
