//
//  WorkflowsView.swift
//  osaurus
//
//  Management view for browsing, inspecting, and deleting workflows.
//  Chat is the primary authoring path (`workflow_save`); this view is
//  read-mostly with light metadata editing.
//

import SwiftUI

// MARK: - Workflows View

struct WorkflowsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var workflows: [Workflow] = []
    @State private var scores: [String: WorkflowScore] = [:]
    @State private var isRefreshing = false
    @State private var hasAppeared = false
    @State private var toastMessage: (text: String, isError: Bool)?
    @State private var editingWorkflow: Workflow?
    @State private var searchText = ""

    private var filteredWorkflows: [Workflow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return workflows }
        return workflows.filter { workflow in
            workflow.name.lowercased().contains(query)
                || workflow.description.lowercased().contains(query)
                || (workflow.triggerText?.lowercased().contains(query) ?? false)
                || workflow.toolsUsed.contains { $0.lowercased().contains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            ZStack {
                if workflows.isEmpty && !isRefreshing {
                    noWorkflowsState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            let shown = filteredWorkflows
                            if shown.isEmpty {
                                emptyState
                            }

                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, workflow in
                                WorkflowRow(
                                    workflow: workflow,
                                    score: scores[workflow.id],
                                    animationDelay: Double(index) * 0.03,
                                    hasAppeared: hasAppeared,
                                    onEdit: { editingWorkflow = workflow },
                                    onDelete: {
                                        Task { @MainActor in
                                            do {
                                                try await WorkflowService.shared.delete(id: workflow.id)
                                                await refresh()
                                                showToast(L("Deleted \"\(workflow.name)\""))
                                            } catch {
                                                showToast(
                                                    L("Delete failed: \(error.localizedDescription)"),
                                                    isError: true
                                                )
                                            }
                                        }
                                    }
                                )
                            }
                        }
                        .padding(24)
                    }
                    .opacity(hasAppeared ? 1 : 0)
                }

                if let toast = toastMessage {
                    VStack {
                        Spacer()
                        ThemedToastView(toast.text, type: toast.isError ? .error : .success)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .sheet(item: $editingWorkflow) { workflow in
            WorkflowEditorSheet(
                workflow: workflow,
                score: scores[workflow.id],
                onSave: { updated in
                    Task { @MainActor in
                        do {
                            try await WorkflowService.shared.update(updated)
                            editingWorkflow = nil
                            await refresh()
                            showToast(L("Updated \"\(updated.name)\""))
                        } catch {
                            showToast(L("Update failed: \(error.localizedDescription)"), isError: true)
                        }
                    }
                },
                onCancel: { editingWorkflow = nil }
            )
        }
        .onAppear {
            Task { @MainActor in
                await refresh()
                withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                    hasAppeared = true
                }
            }
        }
    }

    // MARK: - Data

    @MainActor
    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let loaded = try await WorkflowService.shared.loadAll()
            var loadedScores: [String: WorkflowScore] = [:]
            for workflow in loaded {
                if let score = try? await WorkflowService.shared.loadScore(workflowId: workflow.id) {
                    loadedScores[workflow.id] = score
                }
            }
            workflows = loaded
            scores = loadedScores
        } catch {
            showToast(L("Failed to load workflows: \(error.localizedDescription)"), isError: true)
        }
    }

    // MARK: - Empty State (no workflows at all)

    /// Chat is the authoring path, so the primary action points at enabling
    /// Workflows on an agent instead of a "Create" sheet.
    @ViewBuilder
    private var noWorkflowsState: some View {
        SettingsEmptyState(
            icon: "arrow.triangle.branch",
            title: L("No Workflows Yet"),
            subtitle: L(
                "Capable models save them after multi-step tasks — any model can discover and run them."
            ),
            examples: [
                .init(
                    icon: "wand.and.stars",
                    title: L("Distilled in chat"),
                    description: L("A capable model captures the steps that worked")
                ),
                .init(
                    icon: "magnifyingglass",
                    title: L("Discoverable"),
                    description: L("Surfaced automatically when a task matches")
                ),
                .init(
                    icon: "play.circle",
                    title: L("Runnable"),
                    description: L("Typed parameters, deterministic execution")
                ),
            ],
            primaryAction: .init(
                title: L("Enable in Agents"),
                icon: "person.2",
                handler: { ManagementStateManager.shared.selectedTab = .agents }
            ),
            hasAppeared: hasAppeared
        )
    }

    // MARK: - Empty State (filtered)

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: searchText.isEmpty ? "arrow.triangle.branch" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(theme.tertiaryText)
            if !searchText.isEmpty {
                Text("No workflows match \"\(searchText)\"", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
            } else {
                Text("No workflows here", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithTabs(
            title: L("Workflows"),
            subtitle: L("Reusable procedures distilled from successful tasks"),
            count: workflows.isEmpty ? nil : workflows.count
        ) {
            HeaderIconButton("arrow.clockwise", isLoading: isRefreshing, help: "Refresh workflows") {
                Task { @MainActor in
                    await refresh()
                }
            }
        } tabsRow: {
            HStack {
                Spacer()
                SearchField(text: $searchText, placeholder: "Search workflows", width: 200)
            }
        }
    }

    // MARK: - Toast Helper

    @MainActor
    private func showToast(_ message: String, isError: Bool = false) {
        withAnimation(theme.springAnimation()) {
            toastMessage = (message, isError)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((isError ? 3.5 : 2.5) * 1_000_000_000))
            withAnimation(theme.animationQuick()) {
                toastMessage = nil
            }
        }
    }
}

// MARK: - Workflow Row

private struct WorkflowRow: View {
    @Environment(\.theme) private var theme

    let workflow: Workflow
    let score: WorkflowScore?
    let animationDelay: Double
    let hasAppeared: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var isExpanded = false
    @State private var showDeleteConfirm = false

    private var workflowColor: Color {
        let hue = Double(abs(workflow.name.hashValue % 360)) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    private var isRunnable: Bool { !workflow.steps.isEmpty }

    private var sourceLabel: String {
        if let model = workflow.sourceModel, !model.isEmpty { return model }
        switch workflow.source {
        case .agent: return L("Agent-created")
        case .user: return L("User-created")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(workflowColor.opacity(0.1))
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(workflowColor)
                }
                .frame(width: 36, height: 36)

                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(workflow.name)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundColor(theme.primaryText)

                                if isRunnable {
                                    HStack(spacing: 3) {
                                        Image(systemName: "play.circle")
                                            .font(.system(size: 8))
                                        Text("Runnable", bundle: .module)
                                            .font(.system(size: 9, weight: .medium))
                                    }
                                    .foregroundColor(theme.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(theme.accentColor.opacity(0.1)))
                                }

                                WorkflowScoreBadge(score: score)
                            }

                            Text(workflow.description.isEmpty ? "No description" : workflow.description)
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                        }

                        Spacer()

                        // Source attribution
                        HStack(spacing: 4) {
                            Image(systemName: "cpu")
                                .font(.system(size: 10))
                            Text(sourceLabel)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.tertiaryBackground))

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .padding(.vertical, 4)

                    // Metadata row
                    HStack(spacing: 14) {
                        Label {
                            Text("v\(workflow.version)", bundle: .module)
                        } icon: {
                            Image(systemName: "tag")
                        }
                        if !workflow.parameters.isEmpty {
                            Label {
                                Text("\(workflow.parameters.count) parameter(s)", bundle: .module)
                            } icon: {
                                Image(systemName: "slider.horizontal.3")
                            }
                        }
                        if isRunnable {
                            Label {
                                Text("\(workflow.steps.count) step(s)", bundle: .module)
                            } icon: {
                                Image(systemName: "list.number")
                            }
                        }
                        if !workflow.toolsUsed.isEmpty {
                            Label {
                                Text(workflow.toolsUsed.joined(separator: ", "))
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: "wrench.and.screwdriver")
                            }
                        }
                        Spacer()
                    }
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)

                    // Body preview
                    ScrollView {
                        Text(workflow.body)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )

                    HStack(spacing: 8) {
                        Button(action: onEdit) {
                            HStack(spacing: 4) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 10))
                                Text("Edit", bundle: .module)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.accentColor.opacity(0.1))
                            )
                        }
                        .buttonStyle(PlainButtonStyle())

                        Spacer()

                        Button(action: { showDeleteConfirm = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                                Text("Delete", bundle: .module)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(theme.errorColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.errorColor.opacity(0.1))
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 10)
        .animation(.easeOut(duration: 0.25).delay(animationDelay), value: hasAppeared)
        .themedAlert(
            "Delete Workflow",
            isPresented: $showDeleteConfirm,
            message: "Are you sure you want to delete \"\(workflow.name)\"? This action cannot be undone.",
            primaryButton: .destructive("Delete", action: onDelete),
            secondaryButton: .cancel("Cancel")
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isHovered ? theme.accentColor.opacity(0.2) : theme.cardBorder,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(isHovered ? 0.08 : 0.04),
                radius: isHovered ? 12 : 6,
                x: 0,
                y: isHovered ? 4 : 2
            )
    }
}

// MARK: - Score Badge

/// Compact success-rate + usage badge. Unused workflows show a neutral
/// "New" pill so a fresh save isn't penalized visually.
private struct WorkflowScoreBadge: View {
    @Environment(\.theme) private var theme

    let score: WorkflowScore?

    private var totalRuns: Int {
        guard let score else { return 0 }
        return score.timesSucceeded + score.timesFailed
    }

    private var badgeColor: Color {
        guard let score, totalRuns > 0 else { return theme.tertiaryText }
        if score.successRate >= 0.75 { return .green }
        if score.successRate >= 0.4 { return .orange }
        return theme.errorColor
    }

    var body: some View {
        if let score, totalRuns > 0 {
            HStack(spacing: 3) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 8))
                Text("\(Int(score.successRate * 100))% · \(totalRuns) run(s)", bundle: .module)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(badgeColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(badgeColor.opacity(0.1)))
        } else {
            Text("New", bundle: .module)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.tertiaryBackground))
        }
    }
}

// MARK: - Editor Sheet

/// Read-mostly editor: metadata fields are editable; parameters and
/// steps render as read-only tables since chat is the authoring path.
struct WorkflowEditorSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let workflow: Workflow
    let score: WorkflowScore?
    let onSave: (Workflow) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var descriptionText: String
    @State private var triggerText: String

    init(
        workflow: Workflow,
        score: WorkflowScore?,
        onSave: @escaping (Workflow) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.workflow = workflow
        self.score = score
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: workflow.name)
        _descriptionText = State(initialValue: workflow.description)
        _triggerText = State(initialValue: workflow.triggerText ?? "")
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Edit Workflow", bundle: .module)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.primaryText)
                Spacer()
                WorkflowScoreBadge(score: score)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field(label: L("Name")) {
                        TextField("", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(8)
                            .background(inputBackground)
                    }

                    field(label: L("Description")) {
                        TextField("", text: $descriptionText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .lineLimit(2 ... 4)
                            .padding(8)
                            .background(inputBackground)
                    }

                    field(label: L("Trigger Text")) {
                        TextField(
                            LocalizedStringKey("Example user phrasings that should surface this workflow"),
                            text: $triggerText
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(8)
                        .background(inputBackground)
                    }

                    if !workflow.parameters.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Parameters", bundle: .module)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)

                            VStack(spacing: 0) {
                                ForEach(Array(workflow.parameters.enumerated()), id: \.offset) { index, param in
                                    HStack(spacing: 8) {
                                        Text(param.name)
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(theme.primaryText)
                                        Text(param.type.rawValue)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(theme.accentColor)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(theme.accentColor.opacity(0.1)))
                                        if !param.required {
                                            Text("optional", bundle: .module)
                                                .font(.system(size: 10))
                                                .foregroundColor(theme.tertiaryText)
                                        }
                                        if let def = param.defaultValue {
                                            Text("default: \(def)", bundle: .module)
                                                .font(.system(size: 10))
                                                .foregroundColor(theme.tertiaryText)
                                        }
                                        Spacer()
                                        Text(param.description)
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.secondaryText)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    if index < workflow.parameters.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                            .background(inputBackground)
                        }
                    }

                    if !workflow.steps.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Steps", bundle: .module)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)

                            VStack(spacing: 0) {
                                ForEach(Array(workflow.steps.enumerated()), id: \.offset) { index, step in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(index + 1).")
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                            .foregroundColor(theme.tertiaryText)
                                        switch step.kind {
                                        case .tool:
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(step.toolName ?? "")
                                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                    .foregroundColor(theme.primaryText)
                                                if let template = step.argsTemplate, !template.isEmpty {
                                                    Text(template)
                                                        .font(.system(size: 11, design: .monospaced))
                                                        .foregroundColor(theme.secondaryText)
                                                        .lineLimit(3)
                                                }
                                            }
                                        case .guidance:
                                            HStack(alignment: .top, spacing: 5) {
                                                Image(systemName: "text.bubble")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(theme.accentColor)
                                                    .padding(.top, 2)
                                                Text(step.text ?? "")
                                                    .font(.system(size: 12))
                                                    .foregroundColor(theme.secondaryText)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    if index < workflow.steps.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                            .background(inputBackground)
                        }
                    } else {
                        field(label: L("Body")) {
                            ScrollView {
                                Text(workflow.body)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(theme.primaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 160)
                            .padding(8)
                            .background(inputBackground)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button(action: onCancel) {
                    Text("Cancel", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: save) {
                    Text("Save", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(canSave ? theme.accentColor : theme.accentColor.opacity(0.4))
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 560, height: 560)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
    }

    private func save() {
        var updated = workflow
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.description = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trigger = triggerText.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.triggerText = trigger.isEmpty ? nil : trigger
        updated.version = workflow.version + 1
        updated.updatedAt = Date()
        onSave(updated)
    }

    @ViewBuilder
    private func field(label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
            content()
        }
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(theme.inputBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.inputBorder, lineWidth: 1)
            )
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        WorkflowsView()
    }
#endif
