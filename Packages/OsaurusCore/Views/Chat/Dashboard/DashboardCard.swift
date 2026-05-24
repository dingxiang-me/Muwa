//
//  DashboardCard.swift
//  OsaurusCore
//

import SwiftUI

// MARK: - WidgetCard

struct WidgetCard: View {
    @Environment(\.theme) private var theme

    let widget: DashboardWidget
    let result: WidgetResult
    let onRefresh: () -> Void
    let onRemove: () -> Void
    /// nil disables the "Edit" menu entry (preview-mode cards)
    var onEdit: (() -> Void)? = nil
    /// preview-mode override; bypasses the `WidgetSize`-based default
    var minHeightOverride: CGFloat? = nil

    @State private var isHovered: Bool = false

    /// `WidgetSize` differentiates vertically only — LazyVGrid can't span columns without a custom layout
    private var minHeight: CGFloat {
        if let minHeightOverride { return minHeightOverride }
        switch widget.size {
        case .small: return 140
        case .medium: return 200
        case .large: return 320
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().opacity(0.4)
            bodyContent
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        // preview mode pins exact height; grid mode keeps the flexible min/max so cards
        // expand to whatever the LazyVGrid row decides
        .frame(
            minHeight: minHeightOverride ?? minHeight,
            maxHeight: minHeightOverride ?? .infinity,
            alignment: .top
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
        )
        // keep renderer content inside the card border (matters when height is pinned,
        // e.g. the live preview); in the grid the card grows to fit so nothing is clipped
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isHovered ? theme.accentColor.opacity(0.25) : theme.cardBorder,
                    lineWidth: isHovered ? 1.5 : 1
                )
        )
        .shadow(
            color: Color.black.opacity(isHovered ? 0.08 : 0.04),
            radius: isHovered ? 10 : 5,
            x: 0,
            y: isHovered ? 3 : 2
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .contextMenu { menuItems }
    }

    /// legacy widgets were stored with `title = toolName` ("get_events");
    /// humanize at render time so the user sees "Get Events" without a migration
    private var displayTitle: String {
        let trimmed = widget.title.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != widget.toolName { return widget.title }
        return widget.toolName
            .split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    @ViewBuilder
    private var menuItems: some View {
        if let timestamp = lastUpdatedLabel {
            Text("Updated \(timestamp)")
            Divider()
        }
        Button(action: onRefresh) {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        if let onEdit {
            Button(action: onEdit) {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
        }
        Divider()
        Button(role: .destructive, action: onRemove) {
            Label("Remove", systemImage: "trash")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(displayTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            if case .loading = result {
                ProgressView().scaleEffect(0.6).frame(width: 24, height: 24)
            }

            Menu { menuItems } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(theme.tertiaryBackground))
                    .clipShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .opacity(isHovered ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
    }

    // MARK: Body

    @ViewBuilder
    private var bodyContent: some View {
        switch result {
        case .idle, .loading:
            idleState
        case .error(let message, _):
            errorState(message)
        case .success(let payload, _):
            WidgetRendererView(
                renderer: widget.renderConfig.renderer,
                mapping: widget.renderConfig.mapping,
                payload: payload,
                size: widget.size,
                caption: widget.renderConfig.caption
            )
        }
    }

    private var idleState: some View {
        VStack(spacing: 8) {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 22))
                .foregroundColor(theme.tertiaryText)
            Text("Waiting for first refresh")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func errorState(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.08))
        )
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 6) {
            Spacer()
            if widget.refreshInBackground {
                Image(systemName: "moon.fill")
                    .font(.system(size: 9))
                    .foregroundColor(theme.tertiaryText)
                    .help("Refreshes in background")
            }
        }
    }

    /// computed on menu open so the label is fresh without driving per-second view updates
    private var lastUpdatedLabel: String? {
        guard case let .success(_, fetchedAt) = result else { return nil }
        if Date().timeIntervalSince(fetchedAt) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: fetchedAt, relativeTo: Date())
    }
}

// MARK: - Renderer dispatcher

struct WidgetRendererView: View {
    let renderer: WidgetRenderer
    let mapping: WidgetFieldMapping
    let payload: JSONValue
    /// drives how many rows list/table render before showing "+N more"
    var size: WidgetSize = .medium

    /// user-set stat caption (overrides the auto-derived one)
    var caption: String? = nil

    var body: some View {
        switch renderer {
        case .stat:
            StatRenderer(payload: payload, mapping: mapping, caption: caption)
        case .keyValue:
            KeyValueRenderer(payload: payload)
        case .list:
            ListRenderer(payload: payload, mapping: mapping, size: size)
        case .table:
            TableRenderer(payload: payload, mapping: mapping, size: size)
        case .markdown:
            MarkdownRenderer(payload: payload)
        case .chart:
            ChartRenderer(payload: payload, mapping: mapping)
        case .calendar:
            CalendarRendererView(payload: payload, mapping: mapping)
        case .raw:
            RawRenderer(payload: payload)
        }
    }
}

// MARK: - .chart

private struct ChartRenderer: View {
    @Environment(\.theme) private var theme
    let payload: JSONValue
    let mapping: WidgetFieldMapping

    var body: some View {
        if let spec = DashboardChartBuilder.buildSpec(
            payload: payload,
            mapping: mapping,
            title: nil
        ) {
            DashboardChartView(spec: spec, theme: theme)
                .frame(minHeight: 160)
        } else {
            EmptyRendererState(message: "No chartable data")
        }
    }
}

// MARK: - .stat

private struct StatRenderer: View {
    @Environment(\.theme) private var theme
    let payload: JSONValue
    let mapping: WidgetFieldMapping
    /// user-set caption; overrides the auto-derived label when non-empty
    var caption: String? = nil

    var body: some View {
        let pair = extract()
        // user caption wins; otherwise use whatever we could derive from the data
        let label = caption?.trimmingCharacters(in: .whitespaces).nonEmpty ?? pair.label
        VStack(alignment: .leading, spacing: 4) {
            Text(pair.value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func extract() -> (value: String, label: String?) {
        switch payload {
        case .number(let n):
            return (formatNumber(n), nil)
        case .string(let s):
            return (s, nil)
        case .bool(let b):
            return (b ? "Yes" : "No", nil)
        case .object(let dict):
            // explicit mapping first; otherwise fall back to "value"/"count" or first numeric field
            let valueKey =
                mapping.valueKey
                ?? ["value", "count", "total", "amount"].first(where: { dict[$0] != nil })
                ?? dict.first(where: { if case .number = $0.value { return true } else { return false } })?.key
            let labelKey =
                mapping.titleKey
                ?? ["label", "title", "name"].first(where: { dict[$0] != nil })

            let valueStr = valueKey.flatMap { dict[$0] }.flatMap { scalarString($0) } ?? "—"
            // explicit label field, else a noun derived from the data so the number isn't bare
            let labelStr =
                labelKey.flatMap { dict[$0] }.flatMap { scalarString($0) }
                ?? autoLabel(dict, valueKey: valueKey)
            return (valueStr, labelStr)
        default:
            return ("—", nil)
        }
    }

    /// derives a caption when the payload has no label field: prefers the noun of a wrapped
    /// collection (e.g. `{messages: [...], total: 83}` → "messages"), else the humanized value key
    private func autoLabel(_ dict: [String: JSONValue], valueKey: String?) -> String? {
        for key in ["messages", "items", "results", "data", "rows", "records", "events", "entries"] {
            if case .array = dict[key] ?? .null { return humanizeKey(key) }
        }
        guard let valueKey, !["value"].contains(valueKey) else { return nil }
        return humanizeKey(valueKey)
    }

    private func humanizeKey(_ key: String) -> String {
        key.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." })
            .joined(separator: " ")
    }
}

extension String {
    /// nil when the string is empty, so `?? fallback` chains read cleanly
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - .table

private struct TableRenderer: View {
    @Environment(\.theme) private var theme
    let payload: JSONValue
    let mapping: WidgetFieldMapping
    var size: WidgetSize = .medium

    var body: some View {
        let (columns, rows) = build()
        if rows.isEmpty {
            EmptyRendererState(message: "No rows")
        } else {
            let cap = maxRows(for: size, isTable: true)
            let visible = Array(rows.prefix(cap))
            let overflow = rows.count - visible.count
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(columns, id: \.self) { col in
                        Text(col)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
                Divider().opacity(0.4)
                ForEach(Array(visible.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        ForEach(columns, id: \.self) { col in
                            Text(row[col] ?? "—")
                                .font(.system(size: 11))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if overflow > 0 { moreRow(overflow, theme: theme) }
            }
        }
    }

    /// caps at five columns to keep wide rows from overflowing the card
    private func build() -> (columns: [String], rows: [[String: String]]) {
        let items = arrayItems(from: payload)
        guard !items.isEmpty else {
            return ([], [])
        }
        let objs: [[String: JSONValue]] = items.compactMap {
            if case .object(let d) = $0 { return d }
            return nil
        }
        guard let first = objs.first else { return ([], []) }

        var cols: [String] = []
        if let t = mapping.titleKey, first[t] != nil { cols.append(t) }
        if let s = mapping.subtitleKey, first[s] != nil, !cols.contains(s) { cols.append(s) }
        for key in first.keys.sorted() where !cols.contains(key) {
            cols.append(key)
            if cols.count >= 5 { break }
        }

        let rows: [[String: String]] = objs.map { dict in
            var row: [String: String] = [:]
            for col in cols {
                row[col] = dict[col].flatMap { scalarString($0) }
            }
            return row
        }
        return (cols, rows)
    }
}

// MARK: - .keyValue

private struct KeyValueRenderer: View {
    @Environment(\.theme) private var theme
    let payload: JSONValue

    var body: some View {
        let entries = flatten(payload)
        if entries.isEmpty {
            EmptyRendererState(message: "No data")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entries, id: \.key) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.key)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                        Spacer(minLength: 8)
                        Text(entry.value)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    /// nested objects/arrays are skipped — inference should have routed them elsewhere
    private func flatten(_ value: JSONValue) -> [(key: String, value: String)] {
        guard case .object(let dict) = value else { return [] }
        return dict.keys.sorted().compactMap { key in
            guard let v = dict[key], let str = scalarString(v) else { return nil }
            return (key, str)
        }
    }
}

// MARK: - .list

private struct ListRenderer: View {
    @Environment(\.theme) private var theme
    let payload: JSONValue
    let mapping: WidgetFieldMapping
    var size: WidgetSize = .medium

    var body: some View {
        let rows = buildRows()
        if rows.isEmpty {
            EmptyRendererState(message: "No items")
        } else {
            let cap = maxRows(for: size, isTable: false)
            let visible = Array(rows.prefix(cap))
            let overflow = rows.count - visible.count
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle()
                            .fill(theme.accentColor.opacity(0.7))
                            .frame(width: 5, height: 5)
                            .offset(y: -1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let subtitle = row.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.tertiaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if overflow > 0 { moreRow(overflow, theme: theme) }
            }
        }
    }

    private struct Row {
        let title: String
        let subtitle: String?
    }

    private func buildRows() -> [Row] {
        let items = arrayItems(from: payload)
        let titleKey = mapping.titleKey
        let subtitleKey = mapping.subtitleKey
        return items.compactMap { item -> Row? in
            switch item {
            case .string(let s):
                return Row(title: s, subtitle: nil)
            case .number(let n):
                return Row(title: formatNumber(n), subtitle: nil)
            case .bool(let b):
                return Row(title: b ? "true" : "false", subtitle: nil)
            case .object(let dict):
                let title = pickValue(dict, key: titleKey)
                    ?? DashboardInference.preferredTitleKey(in: dict).flatMap { pickValue(dict, key: $0) }
                    ?? "—"
                let subtitle = pickValue(dict, key: subtitleKey)
                    ?? DashboardInference.preferredSubtitleKey(in: dict, excluding: titleKey)
                        .flatMap { pickValue(dict, key: $0) }
                return Row(title: title, subtitle: subtitle)
            case .array, .null:
                return nil
            }
        }
    }

    private func pickValue(_ dict: [String: JSONValue], key: String?) -> String? {
        guard let key, let value = dict[key] else { return nil }
        return scalarString(value)
    }
}

// MARK: - .markdown

private struct MarkdownRenderer: View {
    @Environment(\.theme) private var theme
    let payload: JSONValue

    var body: some View {
        if let text = extractText(), !text.isEmpty {
            MarkdownMessageView(text: text, baseWidth: 400)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            EmptyRendererState(message: "No content")
        }
    }

    /// accepts top-level strings and `{text: ...}` / `{markdown: ...}` envelope shapes
    private func extractText() -> String? {
        switch payload {
        case .string(let s): return s
        case .object(let dict):
            if case .string(let s) = dict["text"] ?? .null { return s }
            if case .string(let s) = dict["markdown"] ?? .null { return s }
            return nil
        default: return nil
        }
    }
}

// MARK: - .raw

private struct RawRenderer: View {
    @Environment(\.theme) private var theme
    let payload: JSONValue

    var body: some View {
        ScrollView {
            Text(prettyJSON(payload))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 200)
    }

    private func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
            let s = String(data: data, encoding: .utf8)
        else { return "<unencodable>" }
        return s
    }
}

// MARK: - Helpers

private struct EmptyRendererState: View {
    @Environment(\.theme) private var theme
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 18))
                .foregroundColor(theme.tertiaryText)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

/// How many rows a list/table renders before collapsing the rest into a "+N more" line,
/// scaled to the widget's height so content stays within the card.
private func maxRows(for size: WidgetSize, isTable: Bool) -> Int {
    switch size {
    case .small: return isTable ? 3 : 2
    case .medium: return isTable ? 6 : 4
    case .large: return isTable ? 12 : 8
    }
}

/// trailing "+N more" row shown when a list/table is capped
@ViewBuilder
private func moreRow(_ count: Int, theme: ThemeProtocol) -> some View {
    Text("+\(count) more")
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(theme.tertiaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
}

/// Unwraps the row array for list/table renderers. Accepts a top-level array, or finds the
/// array under common envelope keys (e.g. `list_messages` returns `{messages: [...], total}`),
/// or falls back to the object's first array value.
private func arrayItems(from payload: JSONValue) -> [JSONValue] {
    if case .array(let arr) = payload { return arr }
    if case .object(let dict) = payload {
        for key in ["messages", "items", "results", "data", "rows", "records", "events", "entries"] {
            if case .array(let arr) = dict[key] ?? .null { return arr }
        }
        for key in dict.keys.sorted() {
            if case .array(let arr) = dict[key] ?? .null { return arr }
        }
    }
    return []
}

/// returns nil for arrays/objects so callers can fall back to placeholder text
private func scalarString(_ value: JSONValue) -> String? {
    switch value {
    case .string(let s): return s
    case .number(let n): return formatNumber(n)
    case .bool(let b): return b ? "true" : "false"
    case .null: return "—"
    case .array, .object: return nil
    }
}

private func formatNumber(_ n: Double) -> String {
    if n.rounded() == n && abs(n) < 1e15 {
        return String(Int64(n))
    }
    return String(n)
}
