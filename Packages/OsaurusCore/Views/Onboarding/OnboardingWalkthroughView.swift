//
//  OnboardingWalkthroughView.swift
//  osaurus
//
//  Onboarding step 5 — a 4-page tour rendered as an internal carousel.
//
//  Unlike the rest of the flow (which is a navigation stack), the
//  walkthrough is a free-form carousel. Pages can be advanced with the
//  Next button, swiped via mouse drag, or jumped to by clicking a page
//  dot. The global Back button always exits the walkthrough — it never
//  drills internally between pages. The global step indicator is hidden
//  on this step so the carousel's own indicator is the only one shown.
//

import SwiftUI

// MARK: - Walkthrough Page

enum WalkthroughPage: Int, CaseIterable, Identifiable {
    case modes = 0
    case sandbox = 1
    case personal = 2
    case privacy = 3

    var id: Int { rawValue }

    var illustrationAsset: String {
        switch self {
        // No new artwork yet for these two — `OnboardingHeroBody` falls back
        // to the styled placeholder until they land in the asset catalog.
        case .modes: return "osaurus-onboarding-tour-modes"
        case .sandbox: return "osaurus-onboarding-tour-sandbox"
        case .personal: return "osaurus-built"
        case .privacy: return "osaurus-data"
        }
    }

    var headline: LocalizedStringKey {
        switch self {
        case .modes: return "Two modes, one chat"
        case .sandbox: return "Safe sandbox"
        case .personal: return "Built around you"
        case .privacy: return "Your data stays yours"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .modes:
            return
                "Talk back and forth in Chat, or hand off long jobs to Work — background sessions triggered by schedules, webhooks, or plugins."
        case .sandbox:
            return
                "Agents install packages, run scripts, and work with files inside a Linux container — completely isolated from your system."
        case .personal:
            return
                "Specialized agents, voice control, and your own theme. Memory belongs to you, surfaced exactly when the next question needs it."
        case .privacy:
            return "Conversations live on your Mac. Switch models or providers any time without losing your history."
        }
    }
}

// MARK: - State

@MainActor
final class WalkthroughState: ObservableObject {
    @Published var currentPage: WalkthroughPage = .modes
    @Published var direction: OnboardingDirection = .forward

    var pages: [WalkthroughPage] { WalkthroughPage.allCases }
    var pageIndex: Int { pages.firstIndex(of: currentPage) ?? 0 }
    var isLastPage: Bool { pageIndex == pages.count - 1 }

    /// Move forward (positive) or backward (negative). Bounded to the
    /// available pages — drag/click overflow at the edges is a no-op.
    func advance(by step: Int) {
        let next = pageIndex + step
        guard next >= 0, next < pages.count else { return }
        direction = step > 0 ? .forward : .backward
        currentPage = pages[next]
    }

    /// Jump directly to a page (used by the clickable page dots).
    func jump(to page: WalkthroughPage) {
        guard page != currentPage else { return }
        direction = page.rawValue > currentPage.rawValue ? .forward : .backward
        currentPage = page
    }

    /// Walkthrough is a carousel, not a navigation stack — Back always exits.
    func handleBack(parentBack: () -> Void) {
        parentBack()
    }
}

// MARK: - Body

struct WalkthroughBody: View {
    @ObservedObject var state: WalkthroughState

    @Environment(\.theme) private var theme

    /// Drag offset accumulated during an in-progress swipe. Resets to 0
    /// when the gesture ends (either committed by `advance(by:)` or
    /// snapped back by the spring animation).
    @State private var dragOffset: CGFloat = 0

    /// Minimum horizontal travel (in points) before a drag commits to a
    /// page change. Smaller drags spring back to the current page.
    private let dragCommitThreshold: CGFloat = 60

    var body: some View {
        VStack(spacing: 18) {
            carousel
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            pageDots
                .padding(.bottom, 4)
        }
    }

    // MARK: - Carousel

    private var carousel: some View {
        ZStack {
            pageHero(state.currentPage)
                .id(state.currentPage)
                .transition(pageTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .offset(x: dragOffset)
        .animation(.spring(response: 0.55, dampingFraction: 0.88), value: state.currentPage)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.85), value: dragOffset)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Soft-clamp at the edges so dragging past the first/last
                    // page feels rubbery rather than free.
                    let raw = value.translation.width
                    if (state.pageIndex == 0 && raw > 0)
                        || (state.isLastPage && raw < 0)
                    {
                        dragOffset = raw / 3
                    } else {
                        dragOffset = raw
                    }
                }
                .onEnded { value in
                    let predicted = value.predictedEndTranslation.width
                    let committed = abs(predicted) > dragCommitThreshold
                    let direction = predicted < 0 ? 1 : -1
                    if committed {
                        state.advance(by: direction)
                    }
                    withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
        )
    }

    @ViewBuilder
    private func pageHero(_ page: WalkthroughPage) -> some View {
        OnboardingHeroBody(
            illustrationAsset: page.illustrationAsset,
            headline: page.headline,
            subtitle: page.subtitle
        )
    }

    private var pageTransition: AnyTransition {
        let dx: CGFloat = OnboardingMetrics.windowWidth - OnboardingMetrics.leftColumnPadding * 2
        let inOffset = state.direction == .forward ? dx : -dx
        let outOffset = state.direction == .forward ? -dx : dx
        return .asymmetric(
            insertion: .offset(x: inOffset),
            removal: .offset(x: outOffset)
        )
    }

    // MARK: - Page dots (clickable)

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(state.pages) { page in
                pageDot(for: page)
            }
        }
    }

    private func pageDot(for page: WalkthroughPage) -> some View {
        let isCurrent = page == state.currentPage
        return Button {
            state.jump(to: page)
        } label: {
            Capsule()
                .fill(isCurrent ? theme.accentColor : theme.primaryBorder.opacity(0.45))
                .frame(width: isCurrent ? 24 : 8, height: 8)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isCurrent ? Color.clear : theme.primaryBorder.opacity(0.25),
                            lineWidth: 1
                        )
                )
                .contentShape(Capsule().inset(by: -6))
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.currentPage)
        }
        .buttonStyle(.plain)
        .help(Text(page.headline, bundle: .module))
    }
}

// MARK: - CTA

struct WalkthroughCTA: View {
    @ObservedObject var state: WalkthroughState
    let onFinish: () -> Void

    var body: some View {
        if state.isLastPage {
            OnboardingBrandButton(title: "Start using Osaurus", action: onFinish)
                .frame(width: OnboardingMetrics.ctaWidthCompact)
        } else {
            OnboardingBrandButton(title: "Next", action: { state.advance(by: 1) })
                .frame(width: OnboardingMetrics.ctaWidthCompact)
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingWalkthroughView_Previews: PreviewProvider {
        static var previews: some View {
            let state = WalkthroughState()
            return VStack {
                WalkthroughBody(state: state).frame(height: 460)
                WalkthroughCTA(state: state, onFinish: {})
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 620)
        }
    }
#endif
