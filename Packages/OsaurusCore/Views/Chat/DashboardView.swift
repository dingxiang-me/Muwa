//
//  DashboardView.swift
//  OsaurusCore
//

import SwiftUI

struct DashboardView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var viewModel = DashboardViewModel.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var showAddSheet = false
    @State private var editingWidget: DashboardWidget?
    @State private var pinRequest: DashboardPinRequest?

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
        // drain both on appear (request buffered before mount) and on change (request arrives while open)
        .onAppear { drainPendingPinRequest() }
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

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 280), spacing: 20),
                    GridItem(.flexible(minimum: 280), spacing: 20),
                ],
                spacing: 20
            ) {
                ForEach(viewModel.widgets) { widget in
                    WidgetCard(
                        widget: widget,
                        result: viewModel.results[widget.id] ?? .idle,
                        onRefresh: {
                            Task { await viewModel.refresh(id: widget.id) }
                        },
                        onRemove: {
                            viewModel.removeWidget(id: widget.id)
                        },
                        onEdit: {
                            editingWidget = widget
                            showAddSheet = true
                        }
                    )
                    // Drag payload is the widget's UUID as a string —
                    // small, copyable, and avoids hauling the whole
                    // widget through the pasteboard.
                    .draggable(widget.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first,
                            let dragged = UUID(uuidString: raw),
                            dragged != widget.id
                        else { return false }
                        viewModel.moveWidget(id: dragged, before: widget.id)
                        return true
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// posted by the toolbar's `+ Add Widget` button
    static let dashboardAddWidgetRequested = Notification.Name(
        "dashboardAddWidgetRequested"
    )

    /// posted by external surfaces (e.g. chat's right-click menu);
    /// userInfo carries `toolName: String` and `argumentsJSON: String`
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
        // best-effort: fall back to empty object on malformed JSON so the picker still pre-fills
        if let data = argsRaw.data(using: .utf8),
            let parsed = try? JSONDecoder().decode(JSONValue.self, from: data)
        {
            self.arguments = parsed
        } else {
            self.arguments = .object([:])
        }
    }
}

