//
//  DashboardAddWidgetSheet.swift
//  OsaurusCore
//

import SwiftUI

// MARK: - Wizard step

enum WidgetWizardStep: Int, CaseIterable {
    case source = 0
    case configure = 1
    case style = 2
    case schedule = 3

    var title: String {
        switch self {
        case .source: return "Pick a source"
        case .configure: return "Set it up"
        case .style: return "Pick a look"
        case .schedule: return "Set updates"
        }
    }
}

// MARK: - Sheet

struct DashboardAddWidgetSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared

    let editing: DashboardWidget?
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

    // preview
    @State private var previewResult: WidgetResult = .idle
    /// last successful payload; style tweaks re-render from this without re-executing
    @State private var cachedPayload: JSONValue?

    @State private var showSaveAnywayConfirm: Bool = false
    @State private var inferenceApplied: Bool = false
    /// suppresses `onToolChanged`'s reset during initial seed so it doesn't wipe pre-filled args
    @State private var didApplyInitial: Bool = false

    // wizard
    @State private var step: WidgetWizardStep = .source
    /// tracks transition direction for asymmetric slide
    @State private var stepDirection: Int = 1

    var body: some View {
        VStack(spacing: 0) {
            header
            stepIndicator
            Divider().opacity(0.4)
            stepBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 720, height: 720)
        .background(theme.primaryBackground)
        .onAppear { applyEditingState() }
        .onChange(of: selectedTool?.id) { _, _ in onToolChanged() }
        .onChange(of: arguments) { _, _ in onArgumentsChanged() }
    }

    // MARK: Header + progress

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(editing == nil ? "Add Widget" : "Edit Widget")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)
                Text(step.title)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.secondaryBackground)
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(WidgetWizardStep.allCases, id: \.self) { s in
                Capsule()
                    .fill(
                        s.rawValue <= step.rawValue
                            ? theme.accentColor
                            : theme.tertiaryBackground
                    )
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground)
    }

    // MARK: Step body

    @ViewBuilder
    private var stepBody: some View {
        ZStack {
            switch step {
            case .source:
                sourceStep
                    .transition(slideTransition)
            case .configure:
                configureStep
                    .transition(slideTransition)
            case .style:
                styleStep
                    .transition(slideTransition)
            case .schedule:
                scheduleStep
                    .transition(slideTransition)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: step)
    }

    private var slideTransition: AnyTransition {
        let edge: Edge = stepDirection > 0 ? .trailing : .leading
        let oppositeEdge: Edge = stepDirection > 0 ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: edge).combined(with: .opacity),
            removal: .move(edge: oppositeEdge).combined(with: .opacity)
        )
    }

    // MARK: Step 1 — Source

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeading(
                "What do you want to see?",
                subtitle: "Pick a plugin. Try \"calendar\", \"weather\", or \"news\"."
            )
            DashboardToolPicker(selectedTool: $selectedTool)
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(theme.secondaryBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 1)
                )
        }
        .padding(20)
    }

    // MARK: Step 2 — Configure

    private var configureStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                stepHeading(
                    "Set it up",
                    subtitle: "Name your widget and fill in any details it needs."
                )

                fieldGroup("Widget name") {
                    TextField("e.g. Today's weather", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground)
                        )
                }

                if hasParameters {
                    fieldGroup("Details") {
                        DashboardArgsForm(
                            parameters: selectedTool?.parameters,
                            arguments: $arguments
                        )
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("This widget doesn't need any extra details.")
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground.opacity(0.4))
                    )
                }
            }
            .padding(20)
        }
    }

    // MARK: Step 3 — Style

    private var styleStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeading(
                "How should it look?",
                subtitle: "We'll show you a live preview. Pick what fits best."
            )

            HStack(alignment: .top, spacing: 20) {
                // options on the left
                VStack(alignment: .leading, spacing: 10) {
                    Text("Display style")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                    rendererChips

                    Text("Size")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.top, 6)
                    sizeChips
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // preview on the right
                VStack(spacing: 10) {
                    previewArea
                    Button {
                        Task { await runPreview() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: cachedPayload == nil ? "play.fill" : "arrow.clockwise")
                                .font(.system(size: 10))
                            Text(cachedPayload == nil ? "Load preview" : "Reload")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(theme.accentColor.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading || selectedTool == nil)
                    Spacer(minLength: 0)
                }
                .frame(width: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20)
    }

    private var previewArea: some View {
        Group {
            if selectedTool == nil {
                previewPlaceholder
            } else {
                WidgetCard(
                    widget: previewWidget,
                    result: previewResult,
                    onRefresh: { Task { await runPreview() } },
                    onRemove: {},
                    minHeightOverride: previewMinHeight
                )
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: size)
    }

    private var previewPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(theme.tertiaryText)
            Text("Preview will appear here")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(theme.secondaryBackground)
        )
    }

    private var rendererChips: some View {
        VStack(spacing: 6) {
            ForEach(consumerRenderers, id: \.self) { r in
                rendererChip(r)
            }
        }
    }

    private func rendererChip(_ r: WidgetRenderer) -> some View {
        let isSelected = renderer == r
        let info = rendererInfo(r)
        return Button {
            renderer = r
        } label: {
            HStack(spacing: 10) {
                Image(systemName: info.icon)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(info.description)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? theme.accentColor.opacity(0.1) : theme.secondaryBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? theme.accentColor.opacity(0.5) : theme.cardBorder,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var sizeChips: some View {
        HStack(spacing: 8) {
            ForEach([WidgetSize.small, .medium, .large], id: \.self) { s in
                sizeChip(s)
            }
        }
    }

    private func sizeChip(_ s: WidgetSize) -> some View {
        let isSelected = size == s
        return Button {
            size = s
        } label: {
            VStack(spacing: 4) {
                Image(systemName: sizeIcon(s))
                    .font(.system(size: 14))
                Text(sizeLabel(s))
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? theme.accentColor.opacity(0.1) : theme.secondaryBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? theme.accentColor.opacity(0.5) : theme.cardBorder,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Step 4 — Schedule

    private var scheduleStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stepHeading(
                    "Keep it fresh",
                    subtitle: "Choose how often the widget should update on its own."
                )

                fieldGroup("Update frequency") {
                    VStack(spacing: 6) {
                        ForEach(RefreshInterval.allCases, id: \.self) { interval in
                            frequencyRow(interval)
                        }
                    }
                }

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep updating while app is in background")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Text("Off by default to save battery.")
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                    }
                    Spacer()
                    Toggle("", isOn: $refreshInBackground)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .disabled(refreshInterval == .manual)
                .opacity(refreshInterval == .manual ? 0.5 : 1)

                Divider().padding(.vertical, 4)

                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        agentOverrideControl
                        if shouldShowMapping {
                            fieldMappingControls
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Advanced options")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                }
            }
            .padding(20)
        }
    }

    private func frequencyRow(_ interval: RefreshInterval) -> some View {
        let isSelected = refreshInterval == interval
        return Button {
            refreshInterval = interval
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? theme.accentColor : theme.tertiaryText)
                Text(interval.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(theme.primaryText)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? theme.accentColor.opacity(0.08) : theme.secondaryBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? theme.accentColor.opacity(0.4) : theme.cardBorder,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var agentOverrideControl: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use a specific agent")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text("Defaults to your usual agent.")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer()
            Picker("", selection: agentSelectionBinding) {
                Text("Default").tag(UUID?.none)
                ForEach(agentManager.agents) { agent in
                    Text(agent.name).tag(Optional(agent.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 160)
        }
    }

    private var agentSelectionBinding: Binding<UUID?> {
        Binding(get: { agentOverride }, set: { agentOverride = $0 })
    }

    @ViewBuilder
    private var fieldMappingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Which fields to show")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
            Text("Use these only if the preview is showing the wrong field for each row.")
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .padding(.bottom, 4)
            switch renderer {
            case .stat:
                mappingField("Value field", binding: mappingBinding(\.valueKey))
                mappingField("Label field", binding: mappingBinding(\.titleKey))
            case .list:
                mappingField("Title field", binding: mappingBinding(\.titleKey))
                mappingField("Subtitle field", binding: mappingBinding(\.subtitleKey))
            case .table:
                mappingField("Primary column", binding: mappingBinding(\.titleKey))
                mappingField("Secondary column", binding: mappingBinding(\.subtitleKey))
            case .chart:
                mappingField("X-axis field", binding: mappingBinding(\.xKey))
                mappingField("Y-axis field", binding: mappingBinding(\.yKey))
            default:
                EmptyView()
            }
        }
    }

    private func mappingField(_ label: String, binding: Binding<String>) -> some View {
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

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .source {
                Button(action: goBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Back").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if step == .schedule {
                Button { attemptSave() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                        Text(editing == nil ? "Add to Dashboard" : "Save Changes")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(canSave ? theme.accentColor : theme.tertiaryText)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            } else {
                Button(action: goNext) {
                    HStack(spacing: 6) {
                        Text("Continue").font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(canAdvance ? theme.accentColor : theme.tertiaryText)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canAdvance)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.secondaryBackground)
        .alert(
            "Preview returned an error",
            isPresented: $showSaveAnywayConfirm,
            actions: {
                Button("Save anyway") { commitSave() }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text("The preview hit an error. Save anyway — the next refresh may succeed.")
            }
        )
    }

    // MARK: - Navigation

    private func goNext() {
        guard let next = WidgetWizardStep(rawValue: step.rawValue + 1) else { return }
        stepDirection = 1
        // when leaving step 2 with no preview yet, fire one so step 3 already has data
        if step == .configure, cachedPayload == nil, selectedTool != nil {
            Task { await runPreview() }
        }
        withAnimation { step = next }
    }

    private func goBack() {
        guard let prev = WidgetWizardStep(rawValue: step.rawValue - 1) else { return }
        stepDirection = -1
        withAnimation { step = prev }
    }

    private var canAdvance: Bool {
        switch step {
        case .source:
            return selectedTool != nil
        case .configure:
            return !title.trimmingCharacters(in: .whitespaces).isEmpty
        case .style:
            return true
        case .schedule:
            return canSave
        }
    }

    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard selectedTool != nil else { return false }
        if editing != nil, !isLoading { return true }
        switch previewResult {
        case .success, .error: return true
        // allow saving when the user opted to skip preview entirely; we won't error out on idle
        case .idle: return true
        case .loading: return false
        }
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

    /// scaled-down minHeight per size so the preview shows relative differences
    /// without the `.large` (320pt) value blowing past the wizard's preview slot
    private var previewMinHeight: CGFloat {
        switch size {
        case .small: return 160
        case .medium: return 210
        case .large: return 260
        }
    }

    private var isLoading: Bool {
        if case .loading = previewResult { return true }
        return false
    }

    private var hasParameters: Bool {
        guard let params = selectedTool?.parameters else { return false }
        if case .object(let dict) = params,
            case .object(let props) = dict["properties"] ?? .null,
            !props.isEmpty
        {
            return true
        }
        return false
    }

    /// hides `.raw` from the consumer chip list (still selectable via existing widget on edit)
    private var consumerRenderers: [WidgetRenderer] {
        var out: [WidgetRenderer] = [.stat, .keyValue, .list, .table, .markdown, .chart]
        if renderer == .raw { out.append(.raw) }
        return out
    }

    private var shouldShowMapping: Bool {
        switch renderer {
        case .stat, .list, .table, .chart: return true
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

    /// invalidate cached preview when args change; user must hit "Reload" again
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

    private func stepHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(theme.primaryText)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
            content()
        }
    }

    private func rendererInfo(_ r: WidgetRenderer) -> (title: String, description: String, icon: String) {
        switch r {
        case .stat:
            return ("Big number", "Show a single value", "number.circle.fill")
        case .keyValue:
            return ("Details", "Show labels with values", "list.bullet.rectangle")
        case .list:
            return ("List", "One item per row", "list.bullet")
        case .table:
            return ("Table", "Multiple columns of data", "tablecells")
        case .markdown:
            return ("Article", "Formatted text or summary", "doc.text")
        case .chart:
            return ("Chart", "Visualize numbers as a graph", "chart.bar.fill")
        case .raw:
            return ("Raw data", "Show the underlying response", "curlybraces")
        }
    }

    private func sizeIcon(_ s: WidgetSize) -> String {
        switch s {
        case .small: return "rectangle.compress.vertical"
        case .medium: return "rectangle"
        case .large: return "rectangle.expand.vertical"
        }
    }

    private func sizeLabel(_ s: WidgetSize) -> String {
        switch s {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
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
            return .error(message: ToolEnvelope.failureMessage(raw), kind: extractKind(raw))
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

// MARK: - Refresh interval

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
        case .manual: return "Only when I refresh"
        case .oneMinute: return "Every minute"
        case .fiveMinutes: return "Every 5 minutes"
        case .fifteenMinutes: return "Every 15 minutes"
        case .oneHour: return "Every hour"
        }
    }

    /// round stored seconds back to the closest preset so the picker can re-select it
    static func closest(to seconds: Int?) -> RefreshInterval {
        guard let seconds, seconds > 0 else { return .manual }
        let presets: [RefreshInterval] = [.oneMinute, .fiveMinutes, .fifteenMinutes, .oneHour]
        return presets.min(by: { abs($0.rawValue - seconds) < abs($1.rawValue - seconds) }) ?? .manual
    }
}
