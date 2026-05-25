//
//  DashboardView.swift
//  OsaurusCore
//

import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var viewModel = DashboardViewModel.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var showAddSheet = false
    @State private var editingWidget: DashboardWidget?
    @State private var pinRequest: DashboardPinRequest?
    // computed once per view lifetime so reordering widgets (which re-renders body)
    // doesn't reroll the random greeting
    @State private var greeting = DashboardView.makeGreeting()

    // MARK: Interactive reorder
    /// widget currently lifted for dragging
    @State private var draggingId: UUID?
    /// raw gesture translation since the lift began
    @State private var dragTranslation: CGSize = .zero
    /// the lifted widget's slot frame at lift time, to keep it under the cursor after reflow
    @State private var dragStartFrame: CGRect?
    /// cursor location at the last reorder, for movement hysteresis (anti flip-flop)
    @State private var lastReorderCursor: CGPoint?
    /// each card's stable slot frame (grid space), updated via preference
    @State private var cardFrames: [UUID: CGRect] = [:]
    private let gridSpace = "dashboard.grid"

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        ZStack {
            if viewModel.widgets.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.setScenePhase(newPhase)
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardAddWidgetRequested)) { _ in
            editingWidget = nil
            pinRequest = nil
            showAddSheet = true
        }
        // drain on mount (buffered) and on change (arrives while open)
        .onAppear {
            drainPendingPinRequest()
            DashboardBriefingService.shared.dashboardDidAppear()
        }
        .onDisappear { DashboardBriefingService.shared.dashboardDidDisappear() }
        .onChange(of: viewModel.pendingPinRequest) { _, _ in drainPendingPinRequest() }
        .sheet(isPresented: $showAddSheet) {
            DashboardAddWidgetSheet(
                editing: editingWidget,
                prefill: pinRequest,
                onSave: { widget in
                    if editingWidget != nil {
                        viewModel.updateWidget(widget)
                    } else {
                        viewModel.addWidget(widget)
                    }
                    showAddSheet = false
                    editingWidget = nil
                    pinRequest = nil
                },
                onCancel: {
                    showAddSheet = false
                    editingWidget = nil
                    pinRequest = nil
                }
            )
            .environment(\.theme, themeManager.currentTheme)
        }
    }

    private func drainPendingPinRequest() {
        guard let request = viewModel.pendingPinRequest else { return }
        editingWidget = nil
        pinRequest = request
        showAddSheet = true
        viewModel.pendingPinRequest = nil
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.grid.3x1.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(theme.tertiaryText)

            VStack(spacing: 4) {
                Text("Your dashboard is empty")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Pin tools and plugins here for quick at-a-glance access.")
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
            }

            Button {
                NotificationCenter.default.post(name: .dashboardAddWidgetRequested, object: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Widget")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grid

    private static let greetingNouns = [
        "stranger", "explorer", "human", "sunshine", "legend",
        "captain", "champ", "chief", "boss", "wanderer", "night owl",
    ]

    private static func makeGreeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let period: String
        switch hour {
        case 5..<12: period = "Good morning"
        case 12..<17: period = "Good afternoon"
        case 17..<22: period = "Good evening"
        default: period = "Hello"
        }
        let noun = greetingNouns.randomElement() ?? "stranger"
        return "\(period), \(noun)"
    }

    private var greetingHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(greeting)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
            Text(Date.now.formatted(date: .complete, time: .omitted))
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                greetingHeader
                DashboardBriefingBand()
                widgetRows
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }

    /// Single custom-layout container holding every card as a sibling, so reordering the data
    /// animates each card to its new slot. `.large` widgets span full width; others pair into two
    /// columns. Cards report their slot frames for drag hit-testing.
    private var widgetRows: some View {
        let reorderable = viewModel.widgets.count > 1
        return DashboardGridLayout(spacing: 20) {
            ForEach(viewModel.widgets) { widget in
                cell(for: widget)
                    .widgetFullWidth(widget.size == .large)
                    .widgetSlotHeight(Self.slotHeight(for: widget.size))
            }
        }
        .coordinateSpace(.named(gridSpace))
        // the lifted card is drawn here, positioned straight from the cursor, so it never
        // depends on its own (animating) slot — that's what keeps it from wobbling on reflow
        .overlay(alignment: .topLeading) { draggedOverlay }
        .onPreferenceChange(WidgetFramesKey.self) { cardFrames = $0 }
        // one gesture on the *stable* container (not per-cell): reordering a full-width widget
        // reshuffles the cells, which would cancel a gesture hosted on a cell mid-drag
        .gesture(gridDragGesture, including: reorderable ? .all : .subviews)
    }

    /// fixed row height per size (mirrors `WidgetCard.minHeight`), so the grid layout never has to
    /// measure card bodies — measuring them on every drag frame is what made reordering janky
    private static func slotHeight(for size: WidgetSize) -> CGFloat {
        switch size {
        case .small: return 140
        case .medium: return 200
        case .large: return 320
        }
    }

    private func widgetCard(_ widget: DashboardWidget) -> WidgetCard {
        WidgetCard(
            widget: widget,
            result: viewModel.results[widget.id] ?? .idle,
            onRefresh: {
                Task { await viewModel.refresh(id: widget.id) }
            },
            onRemove: {
                viewModel.removeWidget(id: widget.id)
            },
            isRefreshing: viewModel.refreshing.contains(widget.id),
            onEdit: {
                editingWidget = widget
                showAddSheet = true
            }
        )
    }

    @ViewBuilder
    private func cell(for widget: DashboardWidget) -> some View {
        ZStack {
            // stable slot tracker — never transformed, so its measured frame is the true slot
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: WidgetFramesKey.self,
                            value: [widget.id: geo.frame(in: .named(gridSpace))]
                        )
                    }
                )

            widgetCard(widget)
                .frame(maxWidth: .infinity)
                // hide the in-flow card while it's lifted; the overlay shows the real one. it still
                // holds its slot so the surrounding cards reflow into the gap.
                .opacity(draggingId == widget.id ? 0 : 1)
        }
        .frame(maxWidth: .infinity)
    }

    /// the lifted card, following the cursor (start-slot center + raw translation = no slot math)
    @ViewBuilder
    private var draggedOverlay: some View {
        if let id = draggingId,
            let widget = viewModel.widgets.first(where: { $0.id == id }),
            let start = dragStartFrame
        {
            widgetCard(widget)
                .frame(width: start.width, height: start.height)
                .scaleEffect(1.04)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
                .position(
                    x: start.midX + dragTranslation.width,
                    y: start.midY + dragTranslation.height
                )
                .allowsHitTesting(false)
        }
    }

    // MARK: Drag handling

    private var gridDragGesture: some Gesture {
        // plain click-drag: on macOS this doesn't fight scrolling (that's the wheel/two-finger)
        DragGesture(minimumDistance: 6, coordinateSpace: .named(gridSpace))
            .onChanged { value in
                if draggingId == nil {
                    // identify the lifted card by where the drag began
                    guard let hit = cardFrames.first(where: { $0.value.contains(value.startLocation) })?.key
                    else { return }
                    beginDrag(id: hit)
                }
                guard draggingId != nil else { return }
                dragTranslation = value.translation
                updateReorder(cursor: value.location)
            }
            .onEnded { _ in
                if draggingId != nil { endDrag() }
            }
    }

    private func beginDrag(id: UUID) {
        draggingId = id
        dragStartFrame = cardFrames[id]
        dragTranslation = .zero
        lastReorderCursor = nil
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    private func updateReorder(cursor: CGPoint) {
        guard let draggingId,
            let target = cardFrames.first(where: { $0.key != draggingId && $0.value.contains(cursor) })?.key
        else { return }
        // hysteresis: require the cursor to have moved since the last reorder, so a big repack
        // (a full-width widget breaking/forming pairs) can't flip-flop the order under a still cursor
        if let last = lastReorderCursor, hypot(cursor.x - last.x, cursor.y - last.y) < 24 { return }
        lastReorderCursor = cursor
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
            viewModel.moveWidget(id: draggingId, toIndexOf: target)
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func endDrag() {
        guard let id = draggingId, let start = dragStartFrame, let current = cardFrames[id] else {
            clearDrag()
            return
        }
        // settle: glide the overlay from the cursor to the card's final slot center, then hand off
        // to the (now-revealed) in-flow card sitting at exactly that spot
        let settle = CGSize(width: current.midX - start.midX, height: current.midY - start.midY)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            dragTranslation = settle
        } completion: {
            clearDrag()
        }
    }

    private func clearDrag() {
        draggingId = nil
        dragTranslation = .zero
        dragStartFrame = nil
        lastReorderCursor = nil
    }
}

// MARK: - Reorderable grid layout

/// Tags a subview as full-width (a `.large` widget) so the layout gives it its own row.
private struct WidgetFullWidthKey: LayoutValueKey {
    static let defaultValue: Bool = false
}

/// Deterministic row height, so the layout never measures card bodies (the source of drag jank).
private struct WidgetSlotHeightKey: LayoutValueKey {
    static let defaultValue: CGFloat = 200
}

extension View {
    fileprivate func widgetFullWidth(_ value: Bool) -> some View {
        layoutValue(key: WidgetFullWidthKey.self, value: value)
    }

    fileprivate func widgetSlotHeight(_ value: CGFloat) -> some View {
        layoutValue(key: WidgetSlotHeightKey.self, value: value)
    }
}

/// Collects each card's slot frame (grid coordinate space) for drag hit-testing.
private struct WidgetFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Packs cards into rows: full-width cards own a row; others pair into two equal columns. Keeping
/// every card a sibling here (rather than nested HStacks) is what lets reordering animate smoothly.
private struct DashboardGridLayout: Layout {
    var spacing: CGFloat = 20

    private struct Row {
        var indices: [Int]
        var fullWidth: Bool
        var height: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? 0
        guard width > 0 else { return .zero }
        let rows = computeRows(subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + max(0, CGFloat(rows.count - 1)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let width = bounds.width
        guard width > 0 else { return }
        let columnWidth = (width - spacing) / 2
        var y = bounds.minY
        for row in computeRows(subviews: subviews) {
            if row.fullWidth {
                subviews[row.indices[0]].place(
                    at: CGPoint(x: bounds.minX, y: y),
                    anchor: .topLeading, proposal: ProposedViewSize(width: width, height: row.height)
                )
            } else {
                for (column, index) in row.indices.enumerated() {
                    let x = bounds.minX + CGFloat(column) * (columnWidth + spacing)
                    subviews[index].place(
                        at: CGPoint(x: x, y: y),
                        anchor: .topLeading, proposal: ProposedViewSize(width: columnWidth, height: row.height)
                    )
                }
            }
            y += row.height + spacing
        }
    }

    private func computeRows(subviews: Subviews) -> [Row] {
        func height(_ i: Int) -> CGFloat { subviews[i][WidgetSlotHeightKey.self] }
        var rows: [Row] = []
        var pending: Int?
        for i in subviews.indices {
            if subviews[i][WidgetFullWidthKey.self] {
                if let p = pending {
                    rows.append(Row(indices: [p], fullWidth: false, height: height(p)))
                    pending = nil
                }
                rows.append(Row(indices: [i], fullWidth: true, height: height(i)))
            } else if let p = pending {
                rows.append(Row(indices: [p, i], fullWidth: false, height: max(height(p), height(i))))
                pending = nil
            } else {
                pending = i
            }
        }
        if let p = pending {
            rows.append(Row(indices: [p], fullWidth: false, height: height(p)))
        }
        return rows
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// toolbar's `+ Add Widget` button
    static let dashboardAddWidgetRequested = Notification.Name(
        "dashboardAddWidgetRequested"
    )

    /// external surfaces (e.g. chat right-click); userInfo: toolName, argumentsJSON
    static let dashboardPinRequested = Notification.Name(
        "dashboardPinRequested"
    )
}

struct DashboardPinRequest: Equatable {
    let toolName: String
    let arguments: JSONValue

    init?(notification: Notification) {
        guard let info = notification.userInfo,
            let toolName = info["toolName"] as? String,
            let argsRaw = info["argumentsJSON"] as? String
        else { return nil }
        self.toolName = toolName
        // fall back to empty object on malformed JSON so picker still pre-fills
        if let data = argsRaw.data(using: .utf8),
            let parsed = try? JSONDecoder().decode(JSONValue.self, from: data)
        {
            self.arguments = parsed
        } else {
            self.arguments = .object([:])
        }
    }
}

