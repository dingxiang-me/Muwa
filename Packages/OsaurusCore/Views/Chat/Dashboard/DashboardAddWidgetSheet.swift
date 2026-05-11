//
//  DashboardAddWidgetSheet.swift
//  OsaurusCore
//

import SwiftUI

struct DashboardAddWidgetSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared

    /// non-nil = edit mode (save updates instead of appends)
    let editing: DashboardWidget?
    /// pre-fill from external surfaces (e.g. chat's "Pin to Dashboard"); exclusive with `editing`
    let prefill: DashboardPinRequest?
    let onSave: (DashboardWidget) -> Void
    let onCancel: () -> Void

    init(
        editing: DashboardWidget?,
        prefill: DashboardPinRequest? = nil,
        onSave: @escaping (DashboardWidget) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.editing = editing
        self.prefill = prefill
        self.onSave = onSave
        self.onCancel = onCancel
    }

    // configuration state
    @State private var selectedTool: PickableTool?
    @State private var title: String = ""
    @State private var arguments: JSONValue = .object([:])
    @State private var renderer: WidgetRenderer = .raw
    @State private var mapping: WidgetFieldMapping = WidgetFieldMapping()
    @State private var size: WidgetSize = .medium
    @State private var refreshInterval: RefreshInterval = .manual
    @State private var refreshInBackground: Bool = false
    @State private var agentOverride: UUID? = nil
    @State private var showAdvanced: Bool = false

    // preview state machine
    @State private var previewResult: WidgetResult = .idle
    /// last successful payload; renderer/mapping tweaks re-render from this without re-executing
    @State private var cachedPayload: JSONValue?

    @State private var showSaveAnywayConfirm: Bool = false
    @State private var inferenceApplied: Bool = false
    /// suppresses `onToolChanged`'s reset during initial seed so it doesn't wipe pre-filled args
    @State private var didApplyInitial: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                configurationPane
                    .frame(maxWidth: 380)
                Divider().opacity(0.4)
                previewPane
                    .frame(minWidth: 320)
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 880, height: 620)
        .background(theme.primaryBackground)
        .onAppear { applyEditingState() }
        .onChange(of: selectedTool?.id) { _, _ in onToolChanged() }
        .onChange(of: arguments) { _, _ in onArgumentsChanged() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(editing == nil ? "Add Widget" : "Edit Widget")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.secondaryBackground)
    }

    // MARK: Configuration pane

    private var configurationPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionLabel("Tool")
                DashboardToolPicker(selectedTool: $selectedTool)
                    .frame(height: 200)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(theme.secondaryBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )

                if selectedTool != nil {
                    titleField
                    sectionLabel("Arguments")
                    DashboardArgsForm(
                        parameters: selectedTool?.parameters,
                        arguments: $arguments
                    )
                }

                sectionLabel("Rendering")
                rendererPicker
                sizePicker
                fieldMappingForm

                sectionLabel("Refresh")
                refreshControls

                advancedToggle
                if showAdvanced {
                    sectionLabel("Advanced")
                    agentOverrideControl
                }
            }
            .padding(16)
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("title")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                Text("required")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
            }
            TextField("Card title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground)
                )
        }
    }

    private var rendererPicker: some View {
        HStack {
            Text("Renderer")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Spacer()
            Picker("", selection: $renderer) {
                ForEach(WidgetRenderer.allCases, id: \.self) { r in
                    Text(rendererLabel(r)).tag(r)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var sizePicker: some View {
        HStack {
            Text("Size")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Spacer()
            Picker("", selection: $size) {
                Text("Small").tag(WidgetSize.small)
                Text("Medium").tag(WidgetSize.medium)
                Text("Large").tag(WidgetSize.large)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
        }
    }

    @ViewBuilder
    private var fieldMappingForm: some View {
        switch renderer {
        case .stat:
            mappingTextField("Value key", binding: mappingBinding(\.valueKey))
            mappingTextField("Label key", binding: mappingBinding(\.titleKey))
        case .list:
            mappingTextField("Title key", binding: mappingBinding(\.titleKey))
            mappingTextField("Subtitle key", binding: mappingBinding(\.subtitleKey))
        case .table:
            mappingTextField("Primary column", binding: mappingBinding(\.titleKey))
            mappingTextField("Secondary column", binding: mappingBinding(\.subtitleKey))
        case .chart:
            mappingTextField("X-axis key", binding: mappingBinding(\.xKey))
            mappingTextField("Y-axis key", binding: mappingBinding(\.yKey))
        case .keyValue, .markdown, .raw:
            EmptyView()
        }
    }

    private func mappingTextField(_ label: String, binding: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 130, alignment: .leading)
            TextField("(auto)", text: binding)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.tertiaryBackground))
        }
    }

    private func mappingBinding(_ keyPath: WritableKeyPath<WidgetFieldMapping, String?>) -> Binding<String> {
        Binding<String>(
            get: { mapping[keyPath: keyPath] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                mapping[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private var refreshControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Interval")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                Spacer()
                Picker("", selection: $refreshInterval) {
                    ForEach(RefreshInterval.allCases, id: \.self) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            HStack(spacing: 8) {
                Toggle(isOn: $refreshInBackground) { EmptyView() }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(refreshInterval == .manual)
                Text("Refresh while app is in background")
                    .font(.system(size: 11))
                    .foregroundColor(
                        refreshInterval == .manual ? theme.tertiaryText : theme.secondaryText
                    )
                Spacer()
            }
        }
    }

    private var advancedToggle: some View {
        Button {
            withAnimation { showAdvanced.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text("Advanced")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(theme.secondaryText)
        }
        .buttonStyle(.plain)
    }

    private var agentOverrideControl: some View {
        HStack {
            Text("Agent")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            Spacer()
            Picker("", selection: agentSelectionBinding) {
                Text("Default").tag(UUID?.none)
                ForEach(agentManager.agents) { agent in
                    Text(agent.name).tag(Optional(agent.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var agentSelectionBinding: Binding<UUID?> {
        Binding(get: { agentOverride }, set: { agentOverride = $0 })
    }

    // MARK: Preview pane

    private var previewPane: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Preview")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                Spacer()
                if selectedTool != nil {
                    Button {
                        Task { await runPreview() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 9))
                            Text(cachedPayload == nil ? "Run preview" : "Run again")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.accentColor.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }
            }
            previewCard
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var previewCard: some View {
        if selectedTool == nil {
            previewPlaceholder(
                icon: "rectangle.grid.3x1.fill",
                message: "Pick a tool to see a live preview."
            )
        } else {
            WidgetCard(
                widget: previewWidget,
                result: previewResult,
                onRefresh: { Task { await runPreview() } },
                onRemove: {}
            )
            .frame(maxWidth: 360)
            // preview is read-only; menus would be misleading
            .allowsHitTesting(false)
            if case .idle = previewResult {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle").font(.system(size: 10))
                    Text("Run the preview to fetch real data, then tweak the renderer below.")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }
            }
        }
    }

    private func previewPlaceholder(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundColor(theme.tertiaryText)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Button {
                attemptSave()
            } label: {
                Text(editing == nil ? "Add Widget" : "Save")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(canSave ? theme.accentColor : theme.tertiaryText)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground)
        .alert(
            "Tool refresh failed",
            isPresented: $showSaveAnywayConfirm,
            actions: {
                Button("Save anyway") { commitSave() }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text(
                    "The preview returned an error. Save the widget anyway — the next refresh may succeed."
                )
            }
        )
    }

    // MARK: - Derived

    private var previewWidget: DashboardWidget {
        DashboardWidget(
            id: editing?.id ?? UUID(),
            title: title.isEmpty ? (selectedTool?.name ?? "Untitled") : title,
            toolName: selectedTool?.name ?? "",
            arguments: arguments,
            refreshSeconds: refreshInterval.seconds,
            refreshInBackground: refreshInBackground,
            agentId: agentOverride,
            renderConfig: RenderConfig(renderer: renderer, mapping: mapping),
            size: size
        )
    }

    private var isLoading: Bool {
        if case .loading = previewResult { return true }
        return false
    }

    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard selectedTool != nil else { return false }
        // edit mode skips the "must run preview" gate so title-only tweaks save instantly
        if editing != nil, !isLoading { return true }
        switch previewResult {
        case .success, .error: return true
        default: return false
        }
    }

    // MARK: - State sync

    private func applyEditingState() {
        if let editing {
            title = editing.title
            arguments = editing.arguments
            renderer = editing.renderConfig.renderer
            mapping = editing.renderConfig.mapping
            size = editing.size
            refreshInterval = RefreshInterval.closest(to: editing.refreshSeconds)
            refreshInBackground = editing.refreshInBackground
            agentOverride = editing.agentId
            showAdvanced = (editing.agentId != nil)

            if let tool = DashboardToolCatalog.buildCatalog().first(where: { $0.name == editing.toolName }) {
                selectedTool = tool
            }
            didApplyInitial = true
            return
        }
        if let prefill {
            if let tool = DashboardToolCatalog.buildCatalog().first(where: { $0.name == prefill.toolName }) {
                selectedTool = tool
                title = tool.name
            }
            arguments = prefill.arguments
        }
        didApplyInitial = true
    }

    private func onToolChanged() {
        // ignore the assignment fired by `applyEditingState` so it doesn't wipe seeded state
        guard didApplyInitial else { return }

        previewResult = .idle
        cachedPayload = nil
        inferenceApplied = false
        if editing == nil {
            if title.isEmpty, let tool = selectedTool {
                title = tool.name
            }
            arguments = .object([:])
        }
    }

    /// invalidate cached preview when args change; user must hit "Run preview" again
    /// (prevents hammering MCP servers per keystroke)
    private func onArgumentsChanged() {
        guard cachedPayload != nil else { return }
        cachedPayload = nil
        previewResult = .idle
        inferenceApplied = false
    }

    // MARK: - Preview execution

    private func runPreview() async {
        guard let tool = selectedTool else { return }
        previewResult = .loading
        let argsJSON = encodeArgs(arguments)
        do {
            let raw = try await ToolRegistry.shared.execute(
                name: tool.name,
                argumentsJSON: argsJSON
            )
            let result = parseEnvelope(raw)
            previewResult = result
            if case .success(let payload, _) = result {
                cachedPayload = payload
                applyInferenceIfNeeded(payload)
            }
        } catch {
            previewResult = .error(message: error.localizedDescription, kind: nil)
        }
    }

    /// fires once after the first successful preview so later user overrides aren't clobbered;
    /// plugin-declared `defaultRender` wins over shape inference
    private func applyInferenceIfNeeded(_ payload: JSONValue) {
        guard !inferenceApplied else { return }
        inferenceApplied = true
        let inferred = DashboardInference.inferRenderConfig(from: payload)
        let hint = selectedTool.flatMap { DashboardToolCatalog.renderHint(forTool: $0.name) }
        // `.raw` (initial default) and an empty mapping are treated as "untouched"
        if renderer == .raw {
            renderer = hint ?? inferred.renderer
        }
        if mapping == WidgetFieldMapping() {
            mapping = inferred.mapping
        }
    }

    // MARK: - Save

    private func attemptSave() {
        if case .error = previewResult {
            showSaveAnywayConfirm = true
        } else {
            commitSave()
        }
    }

    private func commitSave() {
        onSave(previewWidget)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(theme.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rendererLabel(_ renderer: WidgetRenderer) -> String {
        switch renderer {
        case .stat: return "Stat"
        case .keyValue: return "Key/Value"
        case .list: return "List"
        case .table: return "Table"
        case .markdown: return "Markdown"
        case .chart: return "Chart"
        case .raw: return "Raw JSON"
        }
    }

    private func encodeArgs(_ args: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(args), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }

    /// duplicates `DashboardViewModel.parseEnvelope` so preview state stays local to the sheet
    private func parseEnvelope(_ raw: String) -> WidgetResult {
        if ToolEnvelope.isError(raw) {
            let message = ToolEnvelope.failureMessage(raw)
            let kind = extractKind(raw)
            return .error(message: message, kind: kind)
        }
        if ToolEnvelope.isSuccess(raw) {
            guard let payload = ToolEnvelope.successPayload(raw) else {
                return .success(.null, fetchedAt: Date())
            }
            return .success(jsonValueFromAny(payload), fetchedAt: Date())
        }
        if let data = raw.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        {
            return .success(jsonValueFromAny(parsed), fetchedAt: Date())
        }
        return .success(.string(raw), fetchedAt: Date())
    }

    private func extractKind(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict["kind"] as? String
    }

    private func jsonValueFromAny(_ any: Any) -> JSONValue {
        if any is NSNull { return .null }
        if let b = any as? Bool { return .bool(b) }
        if let n = any as? NSNumber { return .number(n.doubleValue) }
        if let s = any as? String { return .string(s) }
        if let arr = any as? [Any] { return .array(arr.map(jsonValueFromAny)) }
        if let dict = any as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (k, v) in dict { out[k] = jsonValueFromAny(v) }
            return .object(out)
        }
        return .null
    }
}

// MARK: - Refresh interval helper

enum RefreshInterval: Int, CaseIterable, Hashable {
    case manual = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600

    var seconds: Int? {
        self == .manual ? nil : rawValue
    }

    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .oneMinute: return "Every 1 min"
        case .fiveMinutes: return "Every 5 min"
        case .fifteenMinutes: return "Every 15 min"
        case .oneHour: return "Every 1 hour"
        }
    }

    /// round stored seconds back to the closest preset so the picker can re-select it
    static func closest(to seconds: Int?) -> RefreshInterval {
        guard let seconds, seconds > 0 else { return .manual }
        let presets: [RefreshInterval] = [.oneMinute, .fiveMinutes, .fifteenMinutes, .oneHour]
        return presets.min(by: { abs($0.rawValue - seconds) < abs($1.rawValue - seconds) }) ?? .manual
    }
}
