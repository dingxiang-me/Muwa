//
//  OnboardingBodyLayouts.swift
//  osaurus
//
//  Body layout primitives that fill the body slot of `OnboardingChromeShell`:
//
//  - `OnboardingTwoColumnBody` — illustration + helper copy on the left,
//    scrollable form content on the right. Used by Create Agent, Configure
//    AI, and Identity.
//  - `OnboardingHeroBody` — single-column centered illustration + headline
//    + subtitle. Used by Welcome and the Walkthrough's internal pages.
//
//  Both layouts share a graceful illustration placeholder that draws when
//  the supplied imageset hasn't been filled in yet, so the screen never
//  visually collapses around an empty image.
//

import AppKit
import SwiftUI

// MARK: - Two-Column Body

struct OnboardingTwoColumnBody<RightContent: View>: View {
    let illustrationAsset: String?
    let leftHeadline: LocalizedStringKey?
    let leftBody: LocalizedStringKey?
    let subtitle: LocalizedStringKey?
    let rightContent: RightContent

    @Environment(\.theme) private var theme

    init(
        illustrationAsset: String?,
        leftHeadline: LocalizedStringKey? = nil,
        leftBody: LocalizedStringKey? = nil,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder rightContent: () -> RightContent
    ) {
        self.illustrationAsset = illustrationAsset
        self.leftHeadline = leftHeadline
        self.leftBody = leftBody
        self.subtitle = subtitle
        self.rightContent = rightContent()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            leftColumn
                .frame(width: OnboardingMetrics.leftColumnWidth)

            rightColumn
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Left Column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            illustrationBlock

            if leftHeadline != nil || leftBody != nil {
                Spacer().frame(height: OnboardingMetrics.illustrationToHeadline)
            }

            if let headline = leftHeadline {
                Text(headline, bundle: .module)
                    .font(theme.font(size: OnboardingMetrics.leftHeadlineSize, weight: .bold))
                    .foregroundColor(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let body = leftBody {
                Spacer().frame(height: OnboardingMetrics.leftHeadlineToBody)
                Text(body, bundle: .module)
                    .font(theme.font(size: OnboardingMetrics.leftBodySize))
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, OnboardingMetrics.leftColumnPadding)
        .padding(.vertical, OnboardingMetrics.bodyVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var illustrationBlock: some View {
        ZStack {
            Circle()
                .fill(theme.accentColor.opacity(theme.isDark ? 0.16 : 0.10))
                .frame(width: 220, height: 220)
                .blur(radius: 50)

            if let asset = illustrationAsset, OnboardingAssetCheck.exists(asset) {
                Image(asset, bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: OnboardingMetrics.illustrationMaxHeight)
            } else {
                IllustrationPlaceholder()
                    .frame(maxWidth: .infinity, maxHeight: OnboardingMetrics.illustrationMaxHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: OnboardingMetrics.illustrationMaxHeight)
    }

    // MARK: - Right Column

    /// Right column scrolls vertically when content overflows. The optional
    /// `subtitle` is the first row inside the scroll content so it scrolls
    /// with the form (otherwise the chrome would feel busy).
    private var rightColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if let subtitle = subtitle {
                    Text(subtitle, bundle: .module)
                        .font(theme.font(size: OnboardingMetrics.subtitleSize))
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 14)
                }

                rightContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, OnboardingMetrics.rightColumnHorizontalPadding)
            .padding(.vertical, OnboardingMetrics.bodyVerticalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Hero Body

struct OnboardingHeroBody: View {
    let illustrationAsset: String?
    let headline: LocalizedStringKey?
    let subtitle: LocalizedStringKey?

    @Environment(\.theme) private var theme

    init(
        illustrationAsset: String?,
        headline: LocalizedStringKey? = nil,
        subtitle: LocalizedStringKey? = nil
    ) {
        self.illustrationAsset = illustrationAsset
        self.headline = headline
        self.subtitle = subtitle
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                heroIllustration

                if headline != nil || subtitle != nil {
                    Spacer().frame(height: OnboardingMetrics.heroIllustrationToHeadline)
                }

                if let headline = headline {
                    Text(headline, bundle: .module)
                        .font(theme.font(size: OnboardingMetrics.heroHeadlineSize, weight: .bold))
                        .foregroundColor(theme.primaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: OnboardingMetrics.heroMaxTextWidth)
                }

                if let subtitle = subtitle {
                    Spacer().frame(height: OnboardingMetrics.heroHeadlineToSubtitle)
                    Text(subtitle, bundle: .module)
                        .font(theme.font(size: OnboardingMetrics.heroSubtitleSize))
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: OnboardingMetrics.heroMaxTextWidth)
                }

                Spacer(minLength: 0)
                // Pull content slightly above true center so it reads as
                // "above the fold" rather than floating mid-window.
                Color.clear.frame(height: 28)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
            .frame(minHeight: minHeroHeight, alignment: .center)
        }
    }

    private var minHeroHeight: CGFloat {
        // Body region is roughly windowHeight − header − footer.
        OnboardingMetrics.windowHeight - OnboardingMetrics.headerHeight - 110
    }

    private var heroIllustration: some View {
        ZStack {
            Circle()
                .fill(theme.accentColor.opacity(theme.isDark ? 0.16 : 0.10))
                .frame(width: 280, height: 280)
                .blur(radius: 60)

            if let asset = illustrationAsset, OnboardingAssetCheck.exists(asset) {
                Image(asset, bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: OnboardingMetrics.heroIllustrationMaxHeight)
            } else {
                IllustrationPlaceholder()
                    .frame(width: 280, height: OnboardingMetrics.heroIllustrationMaxHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: OnboardingMetrics.heroIllustrationMaxHeight)
    }
}

// MARK: - Illustration Placeholder

/// Friendly placeholder shown until the designer-supplied PNG drops into the
/// imageset. Adapts to light/dark mode via theme tokens.
struct IllustrationPlaceholder: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(theme.isDark ? 0.14 : 0.08),
                            theme.accentColor.opacity(theme.isDark ? 0.06 : 0.04),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            theme.accentColor.opacity(theme.isDark ? 0.2 : 0.18),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 6])
                        )
                )

            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(theme.accentColor.opacity(0.6))
                Text("illustration", bundle: .module)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundColor(theme.accentColor.opacity(0.7))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

// MARK: - Asset existence check

/// Lightweight cached check for whether an imageset has a real PNG behind
/// it. SwiftUI's `Image(_, bundle:)` silently renders nothing when the asset
/// is missing — we want to swap in a friendly placeholder instead.
@MainActor
enum OnboardingAssetCheck {
    private static var cache: [String: Bool] = [:]

    static func exists(_ name: String) -> Bool {
        if let cached = cache[name] { return cached }
        let exists =
            Bundle.module.image(forResource: NSImage.Name(name)) != nil
            || NSImage(named: name) != nil
        cache[name] = exists
        return exists
    }
}
