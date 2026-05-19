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

    /// only `widget: true`-flagged plugin tools appear — keeps the picker curated
    static func buildCatalog() -> [PickableTool] {
        let registry = ToolRegistry.shared
        // hide built-in agent-loop tools (`complete`, `clarify`, `capabilities_*`, etc.) —
        // they're chat infrastructure, not user-facing data sources
        let builtInNames = registry.builtInToolNames
        let entries = registry.listTools().filter {
            guard $0.enabled, !builtInNames.contains($0.name) else { return false }
            return isWidgetReady($0.name)
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

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.secondaryBackground)
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(groupedSections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            groupHeader(section.title)
                            VStack(spacing: 14) {
                                ForEach(section.tools) { tool in
                                    row(tool)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            if catalog.isEmpty {
                emptyState
            }
        }
        .background(theme.primaryBackground)
        .onAppear { rebuildCatalog() }
    }

    private func rebuildCatalog() {
        catalog = DashboardToolCatalog.buildCatalog()
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(theme.tertiaryText)
            Text("No plugins offer widgets yet. Install plugins from the Plugins tab.")
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
        Text(prettyGroupTitle(title))
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(theme.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    /// "osaurus.macos-use" -> "Macos Use", "osaurus.calendar" -> "Calendar"
    private func prettyGroupTitle(_ raw: String) -> String {
        let stripped = raw.hasPrefix("osaurus.")
            ? String(raw.dropFirst("osaurus.".count))
            : raw
        return stripped
            .split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func row(_ tool: PickableTool) -> some View {
        let isSelected = selectedTool?.id == tool.id
        let isDisabled = tool.unavailableReason != nil
        return Button {
            guard !isDisabled else { return }
            selectedTool = tool
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(humanize(tool.name))
                            .font(.system(size: 15, weight: .semibold))
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
                                .font(.system(size: 14))
                                .foregroundColor(theme.accentColor)
                        }
                    }
                    Text(tool.name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
                Text(tool.description)
                    .font(.system(size: 12))
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
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? theme.accentColor.opacity(0.12) : theme.secondaryBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? theme.accentColor.opacity(0.5) : theme.cardBorder.opacity(0.5),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    /// "get_active_window" -> "Get Active Window"
    private func humanize(_ raw: String) -> String {
        raw
            .split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
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
