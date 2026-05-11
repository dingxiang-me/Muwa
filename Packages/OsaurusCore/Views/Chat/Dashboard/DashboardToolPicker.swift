//
//  DashboardToolPicker.swift
//  OsaurusCore
//

import OsaurusRepository
import SwiftUI

struct PickableTool: Identifiable, Equatable {
    /// tool name doubles as id
    let id: String
    let name: String
    let description: String
    let group: ToolGroup
    let effectivePolicy: ToolPermissionPolicy
    let parameters: JSONValue?
    /// nil = fully available; otherwise the row renders disabled with this reason
    let unavailableReason: String?

    enum ToolGroup: Equatable, Hashable {
        case builtIn
        case plugin(String)
        case mcp(String, providerId: UUID?)
        case sandboxPlugin(String)

        var displayName: String {
            switch self {
            case .builtIn: return "Built-in"
            case .plugin(let id): return id
            case .mcp(let provider, _): return provider
            case .sandboxPlugin(let id): return id
            }
        }

        /// keeps group ordering stable across renders
        var sortKey: String {
            switch self {
            case .builtIn: return "0_builtin"
            case .plugin(let id): return "1_plugin_\(id)"
            case .mcp(let p, _): return "2_mcp_\(p)"
            case .sandboxPlugin(let id): return "3_sandbox_\(id)"
            }
        }
    }
}

@MainActor
enum DashboardToolCatalog {
    /// returns the plugin-declared renderer for a tool, if the registry catalog provided one
    static func renderHint(forTool name: String) -> WidgetRenderer? {
        toolSummary(forTool: name)
            .flatMap { $0.defaultRender }
            .flatMap { WidgetRenderer(rawValue: $0) }
    }

    /// returns true if the plugin author flagged this tool as widget-ready
    static func isWidgetReady(_ name: String) -> Bool {
        toolSummary(forTool: name)?.widget == true
    }

    private static func toolSummary(forTool name: String) -> RegistryCapabilities.ToolSummary? {
        for plugin in PluginRepositoryService.shared.plugins {
            guard let tools = plugin.capabilities?.tools else { continue }
            if let match = tools.first(where: { $0.name == name }) { return match }
        }
        return nil
    }

    /// when `showAllPluginTools` is false (default), only `widget: true`-flagged plugin tools
    /// appear — keeps the picker curated for non-technical users. setting true is the
    /// power-user escape hatch surfaced by the picker's "Show all plugin tools" toggle.
    static func buildCatalog(showAllPluginTools: Bool = false) -> [PickableTool] {
        let registry = ToolRegistry.shared
        // hide built-in agent-loop tools (`complete`, `clarify`, `capabilities_*`, etc.) —
        // they're chat infrastructure, not user-facing data sources
        let builtInNames = registry.builtInToolNames
        let entries = registry.listTools().filter {
            guard $0.enabled, !builtInNames.contains($0.name) else { return false }
            return showAllPluginTools || isWidgetReady($0.name)
        }

        // map provider display name → MCPProvider so we can detect connection state per tool
        let mcpManager = MCPProviderManager.shared
        var providerByName: [String: MCPProvider] = [:]
        for provider in mcpManager.configuration.providers {
            providerByName[provider.name] = provider
        }

        var out: [PickableTool] = []
        for entry in entries {
            let policy = registry.policyInfo(for: entry.name)?.effectivePolicy ?? .auto
            // hide `.deny` — pinning a denied tool is pointless
            if policy == .deny { continue }

            let group = classify(entry.name, registry: registry, providerByName: providerByName)

            var unavailableReason: String? = nil
            if case .mcp(_, let providerId?) = group {
                if let state = mcpManager.providerStates[providerId], !state.isConnected {
                    unavailableReason = "Provider is not connected. Open Settings → Providers to connect."
                }
            }

            out.append(
                PickableTool(
                    id: entry.name,
                    name: entry.name,
                    description: entry.description,
                    group: group,
                    effectivePolicy: policy,
                    parameters: entry.parameters,
                    unavailableReason: unavailableReason
                )
            )
        }
        return out
    }

    private static func classify(
        _ toolName: String,
        registry: ToolRegistry,
        providerByName: [String: MCPProvider]
    ) -> PickableTool.ToolGroup {
        if registry.isMCPTool(toolName) {
            let providerName = registry.groupName(for: toolName) ?? "Unknown"
            return .mcp(providerName, providerId: providerByName[providerName]?.id)
        }
        if registry.isPluginTool(toolName) {
            return .plugin(registry.groupName(for: toolName) ?? toolName)
        }
        if registry.isSandboxTool(toolName) {
            return .sandboxPlugin(registry.groupName(for: toolName) ?? toolName)
        }
        return .builtIn
    }
}

// MARK: - View

struct DashboardToolPicker: View {
    @Environment(\.theme) private var theme
    @Binding var selectedTool: PickableTool?
    @State private var searchText: String = ""
    @State private var catalog: [PickableTool] = []
    @State private var showAllPluginTools: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                searchBar
                showAllToggle
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.secondaryBackground)
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedSections, id: \.title) { section in
                        Section {
                            ForEach(section.tools) { tool in
                                row(tool)
                                Divider().opacity(0.25)
                            }
                        } header: {
                            groupHeader(section.title)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            if catalog.isEmpty {
                emptyState
            }
        }
        .background(theme.primaryBackground)
        .onAppear { rebuildCatalog() }
        .onChange(of: showAllPluginTools) { _, _ in rebuildCatalog() }
    }

    private func rebuildCatalog() {
        catalog = DashboardToolCatalog.buildCatalog(showAllPluginTools: showAllPluginTools)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.tertiaryBackground)
        )
    }

    private var showAllToggle: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: $showAllPluginTools)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
            Text("Show all plugin tools")
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryText)
            Spacer()
            if showAllPluginTools {
                Text("Advanced")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.warningColor.opacity(0.15)))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(theme.tertiaryText)
            Text(
                showAllPluginTools
                    ? "No plugin tools found. Install plugins from the Plugins tab."
                    : "No plugins offer widgets yet. Install plugins, or flip on \"Show all plugin tools\" above."
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
    }

    private var filteredCatalog: [PickableTool] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return catalog }
        return catalog.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    private struct ToolGroupSection {
        let title: String
        let tools: [PickableTool]
    }

    private var groupedSections: [ToolGroupSection] {
        let grouped = Dictionary(grouping: filteredCatalog, by: { $0.group })
        return grouped
            .map { ToolGroupSection(title: $0.key.displayName, tools: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.tools.first?.group.sortKey ?? "" < $1.tools.first?.group.sortKey ?? "" }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(theme.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.secondaryBackground)
    }

    private func row(_ tool: PickableTool) -> some View {
        let isSelected = selectedTool?.id == tool.id
        let isDisabled = tool.unavailableReason != nil
        return Button {
            guard !isDisabled else { return }
            selectedTool = tool
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(isDisabled ? theme.tertiaryText : theme.primaryText)
                        .lineLimit(1)
                    if tool.effectivePolicy == .ask {
                        policyBadge(
                            "Will prompt",
                            icon: "hand.raised.fill",
                            color: theme.warningColor
                        )
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(theme.accentColor)
                    }
                }
                Text(tool.description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
                if let reason = tool.unavailableReason {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        Text(reason)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Rectangle()
                    .fill(isSelected ? theme.accentColor.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private func policyBadge(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(text).font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundColor(color)
    }
}
