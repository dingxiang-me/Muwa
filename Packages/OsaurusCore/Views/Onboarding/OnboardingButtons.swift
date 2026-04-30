//
//  OnboardingButtons.swift
//  osaurus
//
//  Buttons used across the onboarding flow.
//  Three filled buttons (`Primary`, `Stateful`, `Shimmer`) share a common
//  layered background via `FilledOnboardingButton` to remove ~250 lines of
//  duplicated gradient/border/glow code.
//

import SwiftUI

// MARK: - Stateful Button State

/// Reflects the result of an in-flight connection test for `OnboardingStatefulButton`.
enum OnboardingButtonState: Equatable {
    case idle
    case loading
    case success
    case error(String)
}

// MARK: - Shared Filled-Button Background

/// Glow + gradient + highlight + border layers shared by every filled
/// onboarding button (primary / stateful / shimmer). The optional `overlay`
/// closure is used by the shimmer button to inject its animated highlight.
private struct FilledOnboardingButtonBackground<Overlay: View>: View {
    let color: Color
    let isEnabled: Bool
    let isHovered: Bool
    let glowRadiusNormal: CGFloat
    let glowRadiusHover: CGFloat
    let glowOpacityNormal: Double
    let glowOpacityHover: Double
    let borderHighlight: Double
    let overlay: Overlay

    init(
        color: Color,
        isEnabled: Bool,
        isHovered: Bool,
        glowRadiusNormal: CGFloat = OnboardingStyle.buttonGlowRadiusNormal,
        glowRadiusHover: CGFloat = OnboardingStyle.buttonGlowRadiusHover,
        glowOpacityNormal: Double = OnboardingStyle.buttonGlowOpacityNormal,
        glowOpacityHover: Double = OnboardingStyle.buttonGlowOpacityHover,
        borderHighlight: Double = 0.25,
        @ViewBuilder overlay: () -> Overlay = { EmptyView() }
    ) {
        self.color = color
        self.isEnabled = isEnabled
        self.isHovered = isHovered
        self.glowRadiusNormal = glowRadiusNormal
        self.glowRadiusHover = glowRadiusHover
        self.glowOpacityNormal = glowOpacityNormal
        self.glowOpacityHover = glowOpacityHover
        self.borderHighlight = borderHighlight
        self.overlay = overlay()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: OnboardingMetrics.buttonCornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            // Glow behind the button
            shape
                .fill(color)
                .blur(radius: isHovered ? glowRadiusHover : glowRadiusNormal)
                .opacity(isEnabled ? (isHovered ? glowOpacityHover : glowOpacityNormal) : 0)
                .scaleEffect(isHovered ? 1.03 : 1.0)

            // Main fill with vertical depth gradient
            shape
                .fill(
                    LinearGradient(
                        colors: [color.opacity(1.0), color, color.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(overlay)
                .clipShape(shape)

            // Top-edge inner highlight
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isEnabled ? 0.2 : 0.1),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )

            // Diagonal gradient border for dimension
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(borderHighlight),
                            Color.white.opacity(borderHighlight * 0.4),
                            Color.black.opacity(0.1),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }
}

// MARK: - Primary Button

/// Primary action button — solid accent color with subtle glow and gradient depth.
struct OnboardingPrimaryButton: View {
    let title: String
    let action: () -> Void
    var isEnabled: Bool = true

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                FilledOnboardingButtonBackground(
                    color: isEnabled ? theme.accentColor : theme.tertiaryText,
                    isEnabled: isEnabled,
                    isHovered: isHovered
                )

                Text(LocalizedStringKey(title), bundle: .module)
                    .font(theme.font(size: 15, weight: .semibold))
                    .foregroundColor(theme.isDark ? theme.primaryText : .white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: OnboardingMetrics.buttonHeight)
            .scaleEffect(isHovered && isEnabled ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) { isHovered = hovering }
        }
    }
}

// MARK: - Stateful Button

/// Brand-styled button that reflects the result of an in-flight connection test.
/// Idle/loading use `theme.buttonBackground` (cream/navy); success/error switch to
/// their semantic colors. Capsule-shaped to match `OnboardingBrandButton`.
struct OnboardingStatefulButton: View {
    let state: OnboardingButtonState
    let idleTitle: LocalizedStringKey
    let loadingTitle: LocalizedStringKey
    let successTitle: LocalizedStringKey
    let errorTitle: LocalizedStringKey
    let action: () -> Void
    var isEnabled: Bool = true

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var shimmerPhase: CGFloat = -0.4

    private var currentTitle: LocalizedStringKey {
        switch state {
        case .idle: return idleTitle
        case .loading: return loadingTitle
        case .success: return successTitle
        case .error: return errorTitle
        }
    }

    private var iconName: String? {
        switch state {
        case .idle: return "arrow.right"
        case .loading: return nil
        case .success: return "checkmark"
        case .error: return "arrow.clockwise"
        }
    }

    private var fillColor: Color {
        switch state {
        case .idle, .loading: return shouldDisable ? theme.tertiaryText : theme.buttonBackground
        case .success: return theme.successColor
        case .error: return theme.errorColor
        }
    }

    private var labelColor: Color {
        switch state {
        case .idle, .loading: return theme.isDark ? Color(hex: "#0e1120") : .white
        case .success, .error: return .white
        }
    }

    private var shouldDisable: Bool { !isEnabled || state == .loading }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer glow — kept very soft so the button stays grounded
                // in the footer instead of looking like a floating halo.
                Capsule()
                    .fill(fillColor)
                    .blur(radius: isHovered ? 6 : 4)
                    .opacity(shouldDisable ? 0 : (isHovered ? 0.22 : 0.12))
                    .scaleEffect(isHovered ? 1.02 : 1.0)

                // Main fill
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [fillColor.opacity(1.0), fillColor.opacity(0.9)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Sweep shimmer (idle only)
                if state == .idle {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0),
                                Color.white.opacity(0.28),
                                Color.white.opacity(0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 50)
                        .offset(x: shimmerPhase * geo.size.width)
                        .blur(radius: 1.5)
                    }
                    .clipShape(Capsule())
                }

                // Top-edge highlight
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )

                // Border
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.4), Color.white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )

                // Label
                HStack(spacing: 8) {
                    if state == .loading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: labelColor))
                            .scaleEffect(0.8)
                    } else if let icon = iconName {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .bold))
                            .offset(x: state == .idle && isHovered ? 2 : 0)
                    }

                    Text(currentTitle)
                        .font(theme.font(size: 15, weight: .semibold))
                }
                .foregroundColor(labelColor)
            }
            .frame(maxWidth: .infinity)
            .frame(height: OnboardingMetrics.buttonHeight)
            .scaleEffect(isHovered && !shouldDisable ? 1.015 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(shouldDisable)
        .onHover { hovering in
            withAnimation(theme.springAnimation()) { isHovered = hovering && !shouldDisable }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: false)) {
                shimmerPhase = 1.4
            }
        }
        .animation(theme.springAnimation(), value: state)
    }
}

// MARK: - Shimmer Button

/// Polished primary button with a continuously animating shimmer overlay.
struct OnboardingShimmerButton: View {
    let title: String
    let action: () -> Void
    var isEnabled: Bool = true

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var shimmerPhase: CGFloat = -0.3

    var body: some View {
        Button(action: action) {
            ZStack {
                FilledOnboardingButtonBackground(
                    color: isEnabled ? theme.accentColor : theme.tertiaryText,
                    isEnabled: isEnabled,
                    isHovered: isHovered,
                    glowRadiusNormal: 14,
                    glowRadiusHover: 18,
                    glowOpacityNormal: 0.35,
                    glowOpacityHover: 0.5,
                    borderHighlight: 0.35
                ) {
                    shimmerOverlay
                }

                Text(LocalizedStringKey(title), bundle: .module)
                    .font(theme.font(size: 15, weight: .semibold))
                    .foregroundColor(theme.isDark ? theme.primaryText : .white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: OnboardingMetrics.buttonHeight)
            .scaleEffect(isHovered && isEnabled ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) { isHovered = hovering }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) {
                shimmerPhase = 1.3
            }
        }
    }

    private var shimmerOverlay: some View {
        GeometryReader { geometry in
            LinearGradient(
                colors: [
                    Color.white.opacity(0),
                    Color.white.opacity(0.35),
                    Color.white.opacity(0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 40)
            .offset(x: shimmerPhase * geometry.size.width)
            .blur(radius: 1)
        }
        .clipped()
    }
}

// MARK: - Brand CTA Button

/// Hero welcome button — capsule-shaped, filled with `theme.buttonBackground`
/// (cream on dark, navy on light) so it uses the brand palette rather than
/// the generic accent colour. Includes a sweep-shimmer and lift-on-hover.
struct OnboardingBrandButton: View {
    let title: String
    let action: () -> Void
    var isEnabled: Bool = true

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var shimmerPhase: CGFloat = -0.4

    private var fillColor: Color { isEnabled ? theme.buttonBackground : theme.tertiaryText }
    private var labelColor: Color { theme.isDark ? Color(hex: "#0e1120") : Color.white }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer glow — kept very soft so the button stays grounded
                // in the footer instead of looking like a floating halo.
                Capsule()
                    .fill(fillColor)
                    .blur(radius: isHovered ? 6 : 4)
                    .opacity(isHovered ? 0.22 : 0.12)
                    .scaleEffect(isHovered ? 1.02 : 1.0)

                // Main fill
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                fillColor.opacity(1.0),
                                fillColor.opacity(0.9),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Sweep shimmer
                GeometryReader { geo in
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.28),
                            Color.white.opacity(0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 50)
                    .offset(x: shimmerPhase * geo.size.width)
                    .blur(radius: 1.5)
                }
                .clipShape(Capsule())

                // Top-edge inner highlight
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )

                // Border
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.4),
                                Color.white.opacity(0.1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )

                // Label + arrow
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(title), bundle: .module)
                        .font(theme.font(size: 15, weight: .semibold))

                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .offset(x: isHovered ? 2 : 0)
                }
                .foregroundColor(labelColor)
            }
            .frame(maxWidth: .infinity)
            .frame(height: OnboardingMetrics.buttonHeight)
            .scaleEffect(isHovered ? 1.015 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(theme.springAnimation()) { isHovered = hovering && isEnabled }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: false)) {
                shimmerPhase = 1.4
            }
        }
    }
}

// MARK: - Secondary Button

/// Glass secondary action button with a gradient border.
struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: OnboardingMetrics.buttonCornerRadius, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if theme.glassEnabled {
                    shape.fill(.ultraThinMaterial)
                }

                shape.fill(
                    isHovered
                        ? theme.cardBackground.opacity(theme.glassEnabled ? 0.9 : 1.0)
                        : theme.cardBackground.opacity(theme.glassEnabled ? 0.6 : 0.8)
                )

                shape.fill(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(isHovered ? 0.08 : 0.03),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            isHovered
                                ? theme.accentColor.opacity(0.5)
                                : theme.glassEdgeLight.opacity(theme.isDark ? 0.25 : 0.35),
                            theme.primaryBorder.opacity(theme.isDark ? 0.3 : 0.4),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

                Text(LocalizedStringKey(title), bundle: .module)
                    .font(theme.font(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: OnboardingMetrics.buttonHeight)
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) { isHovered = hovering }
        }
    }
}

// MARK: - Text Button

/// Text-only tertiary button (e.g. "Skip for now", "Download later").
struct OnboardingTextButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(theme.font(size: 13, weight: .medium))
                .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
                .underline(isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) { isHovered = hovering }
        }
    }
}

// MARK: - Back Button

/// Back chevron + label used in `OnboardingScaffold`'s top bar.
struct OnboardingBackButton: View {
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text("Back", bundle: .module)
                    .font(theme.font(size: 13, weight: .medium))
            }
            .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? theme.cardBackground.opacity(0.6) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Outdent so the chevron visually aligns with the content's leading edge
        // rather than the back button's interior padding.
        .padding(.leading, -12)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) { isHovered = hovering }
        }
    }
}
