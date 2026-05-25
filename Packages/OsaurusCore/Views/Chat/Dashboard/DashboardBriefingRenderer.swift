//
//  DashboardBriefingRenderer.swift
//  OsaurusCore
//

import SwiftUI

// MARK: - Segment schema
//
// Plugins return:
//   { "segments": [ { "type": "...", ... }, ... ] }
// or a bare array of segments. Each segment is one of:
//
//   { "type": "text",      "value": "Hey, " }
//   { "type": "pill",      "label": "In Progress", "tone": "success" }      // tone: neutral|accent|success|warning|danger
//   { "type": "avatar",    "url": "https://...", "label": "alice" }         // label = a11y / fallback initial
//   { "type": "avatars",   "urls": ["https://...", "..."], "max": 3 }
//   { "type": "icon",      "name": "bubble.left.fill", "tone": "accent" }   // SF Symbol
//   { "type": "count",     "value": 5, "label": "unread comments" }         // bold number + trailing label
//   { "type": "dateChip",  "iso": "2026-08-19", "label": "AUG 19" }         // calendar-style chip
//
// Anything unrecognized is dropped silently — keeps the schema forward-compatible.

enum BriefingTone: String, Sendable {
    case neutral, accent, success, warning, danger

    func color(_ theme: ThemeProtocol) -> Color {
        switch self {
        case .neutral: return theme.secondaryText
        case .accent: return theme.accentColor
        case .success: return .green
        case .warning: return theme.warningColor
        case .danger: return .red
        }
    }
}

enum BriefingSegment: Sendable {
    case text(String)
    case pill(label: String, tone: BriefingTone)
    case avatar(url: URL?, label: String?)
    case avatars(urls: [URL?], max: Int)
    case icon(name: String, tone: BriefingTone)
    case count(value: Int, label: String?)
    case dateChip(date: Date?, label: String)

    static func parse(_ payload: JSONValue) -> [BriefingSegment] {
        let raw: [JSONValue]
        switch payload {
        case .array(let items):
            raw = items
        case .object(let dict):
            if case .array(let items) = dict["segments"] ?? .null { raw = items } else { return [] }
        default:
            return []
        }
        return raw.compactMap(parseOne)
    }

    private static func parseOne(_ value: JSONValue) -> BriefingSegment? {
        guard case .object(let dict) = value,
            case .string(let type) = dict["type"] ?? .null
        else { return nil }

        switch type {
        case "text":
            guard case .string(let s) = dict["value"] ?? .null else { return nil }
            return .text(s)
        case "pill":
            guard case .string(let label) = dict["label"] ?? .null else { return nil }
            return .pill(label: label, tone: tone(dict["tone"]))
        case "avatar":
            return .avatar(url: url(dict["url"]), label: string(dict["label"]))
        case "avatars":
            guard case .array(let arr) = dict["urls"] ?? .null else { return nil }
            let urls = arr.map { url($0) }
            let max = int(dict["max"]) ?? 3
            return .avatars(urls: urls, max: max)
        case "icon":
            guard case .string(let name) = dict["name"] ?? .null else { return nil }
            return .icon(name: name, tone: tone(dict["tone"]))
        case "count":
            guard let v = int(dict["value"]) else { return nil }
            return .count(value: v, label: string(dict["label"]))
        case "dateChip":
            return .dateChip(date: iso(dict["iso"]), label: string(dict["label"]) ?? "")
        default:
            return nil
        }
    }

    private static func string(_ v: JSONValue?) -> String? {
        if case .string(let s) = v ?? .null { return s }
        return nil
    }
    private static func int(_ v: JSONValue?) -> Int? {
        if case .number(let n) = v ?? .null { return Int(n) }
        return nil
    }
    private static func url(_ v: JSONValue?) -> URL? {
        string(v).flatMap { URL(string: $0) }
    }
    private static func tone(_ v: JSONValue?) -> BriefingTone {
        BriefingTone(rawValue: string(v) ?? "") ?? .neutral
    }
    /// ISO8601DateFormatter is documented thread-safe; the `nonisolated(unsafe)`
    /// is just to satisfy Swift 6's stricter Sendable check on stored statics.
    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
    private static func iso(_ v: JSONValue?) -> Date? {
        string(v).flatMap { isoFormatter.date(from: $0) }
    }
}

// MARK: - Renderer

struct BriefingRenderer: View {
    @Environment(\.theme) private var theme
    let payload: JSONValue

    var body: some View {
        let segments = BriefingSegment.parse(payload)
        if segments.isEmpty {
            EmptyBriefingState()
        } else {
            BriefingFlowLayout(spacing: 6, lineSpacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    segmentView(segment)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: BriefingSegment) -> some View {
        switch segment {
        case .text(let value):
            // split on whitespace so each word can wrap independently in the flow layout
            ForEach(splitWords(value), id: \.self) { word in
                Text(word)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
        case .pill(let label, let tone):
            PillView(label: label, color: tone.color(theme))
        case .avatar(let url, let label):
            AvatarView(url: url, fallback: label)
        case .avatars(let urls, let max):
            AvatarStackView(urls: Array(urls.prefix(max)))
        case .icon(let name, let tone):
            Image(systemName: name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(tone.color(theme))
        case .count(let value, let label):
            HStack(spacing: 4) {
                Text("\(value)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(theme.primaryText)
                if let label, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(theme.primaryText)
                }
            }
        case .dateChip(let date, let label):
            DateChipView(date: date, fallbackLabel: label)
        }
    }

    private func splitWords(_ value: String) -> [String] {
        // keep leading/trailing spaces folded in so punctuation hugs the prior token
        var out: [String] = []
        var current = ""
        for ch in value {
            if ch.isWhitespace {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

private struct EmptyBriefingState: View {
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 18))
                .foregroundColor(theme.tertiaryText)
            Text("No briefing segments")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

// MARK: - Pill

private struct PillView: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(color)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.18)))
    }
}

// MARK: - Avatar

private struct AvatarView: View {
    @Environment(\.theme) private var theme
    let url: URL?
    let fallback: String?
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(theme.cardBorder, lineWidth: 0.5))
    }

    @ViewBuilder private var initials: some View {
        Text(String(fallback?.prefix(1) ?? "?").uppercased())
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundColor(theme.secondaryText)
            .frame(width: size, height: size)
            .background(theme.tertiaryBackground)
    }
}

private struct AvatarStackView: View {
    let urls: [URL?]
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(Array(urls.enumerated()), id: \.offset) { _, u in
                AvatarView(url: u, fallback: nil, size: size)
            }
        }
    }
}

// MARK: - Date chip

private struct DateChipView: View {
    @Environment(\.theme) private var theme
    let date: Date?
    let fallbackLabel: String

    var body: some View {
        VStack(spacing: 0) {
            Text(monthLabel)
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.9))
            Text(dayLabel)
                .font(.system(size: 11, weight: .bold))
                // chip background is always white, so pin a dark color (theme.primaryText
                // is white in dark mode → invisible day number)
                .foregroundColor(Color(white: 0.1))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
        }
        .frame(width: 26)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.cardBorder, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var monthLabel: String {
        if let date {
            let f = DateFormatter()
            f.dateFormat = "MMM"
            return f.string(from: date).uppercased()
        }
        return fallbackLabel.split(separator: " ").first.map(String.init) ?? ""
    }
    private var dayLabel: String {
        if let date {
            return String(Calendar.current.component(.day, from: date))
        }
        return fallbackLabel.split(separator: " ").dropFirst().first.map(String.init) ?? fallbackLabel
    }
}

// MARK: - Flow layout
//
// Wraps subviews left-to-right, top-to-bottom. Avoids Text concatenation so we can
// mix arbitrary views (pills, avatars, chips) inline.

private struct BriefingFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layoutRows(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } + max(0, CGFloat(rows.count - 1)) * lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layoutRows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = subviews[item.index].sizeThatFits(.unspecified)
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, width: CGFloat)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layoutRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let projected = current.width + (current.items.isEmpty ? 0 : spacing) + size.width
            if projected > maxWidth && !current.items.isEmpty {
                rows.append(current)
                current = Row()
            }
            if !current.items.isEmpty { current.width += spacing }
            current.items.append((index, size.width))
            current.width += size.width
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
