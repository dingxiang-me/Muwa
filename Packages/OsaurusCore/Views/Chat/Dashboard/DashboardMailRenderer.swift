//
//  DashboardMailRenderer.swift
//  OsaurusCore
//

import SwiftUI

// MARK: - Model

struct MailItem: Identifiable, Equatable {
    let id: String
    /// display name resolved from a `from`/`sender` field ("Maya Lin <m@x.com>" -> "Maya Lin")
    let sender: String
    let subject: String
    let date: Date?
    let isRead: Bool
    let isFlagged: Bool
}

// MARK: - Adapter

enum MailPayloadAdapter {
    /// Parses a `list_messages`-style payload (`{messages: [...]}` or a bare array) into mail rows.
    static func parse(_ payload: JSONValue, mapping: WidgetFieldMapping) -> [MailItem] {
        items(from: payload).compactMap { value in
            guard case .object(let dict) = value else { return nil }
            let from = readString(dict, keys: ["from", "sender", "from_name", "from_address", "author"]) ?? ""
            let subject =
                readString(dict, keys: [mapping.titleKey, "subject", "title", "summary"]) ?? "(no subject)"
            let dateStr = readString(dict, keys: [mapping.subtitleKey, "date", "received", "received_at", "timestamp", "sent_at"])
            let id = readString(dict, keys: ["message_id", "id", "uid"]) ?? UUID().uuidString
            return MailItem(
                id: id,
                sender: displayName(from),
                subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                date: dateStr.flatMap(parseDate),
                isRead: readBool(dict, keys: ["is_read", "read", "seen"]) ?? true,
                isFlagged: readBool(dict, keys: ["is_flagged", "flagged", "starred", "urgent", "important"]) ?? false
            )
        }
    }

    /// count of unread messages on the fetched page (surfaced in the card title)
    static func unreadCount(_ payload: JSONValue, mapping: WidgetFieldMapping) -> Int {
        parse(payload, mapping: mapping).filter { !$0.isRead }.count
    }

    /// "Maya Lin <maya@x.com>" -> "Maya Lin"; "maya@x.com" -> "maya"; else the raw string
    static func displayName(_ from: String) -> String {
        let trimmed = from.trimmingCharacters(in: .whitespaces)
        if let lt = trimmed.firstIndex(of: "<") {
            let name = trimmed[..<lt]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !name.isEmpty { return name }
        }
        if trimmed.contains("@"), let local = trimmed.split(separator: "@").first {
            return String(local)
        }
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    private static func items(from payload: JSONValue) -> [JSONValue] {
        if case .array(let arr) = payload { return arr }
        if case .object(let dict) = payload {
            for key in ["messages", "items", "results", "data", "rows", "records", "entries"] {
                if case .array(let arr) = dict[key] ?? .null { return arr }
            }
            for key in dict.keys.sorted() {
                if case .array(let arr) = dict[key] ?? .null { return arr }
            }
        }
        return []
    }

    private static func readString(_ dict: [String: JSONValue], keys: [String?]) -> String? {
        for case let key? in keys {
            if case .string(let s) = dict[key] ?? .null, !s.isEmpty { return s }
        }
        return nil
    }

    private static func readBool(_ dict: [String: JSONValue], keys: [String]) -> Bool? {
        for key in keys {
            if case .bool(let b) = dict[key] ?? .null { return b }
        }
        return nil
    }

    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func parseDate(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}

// MARK: - Renderer

struct MailRendererView: View {
    @Environment(\.theme) private var theme
    let payload: JSONValue
    let mapping: WidgetFieldMapping
    var size: WidgetSize = .medium

    // kept in sync with DashboardView.slotHeight(for:) so the card is exactly as tall as its rows
    private var maxRows: Int {
        switch size {
        case .small: return 2
        case .medium: return 4
        case .large: return 7
        }
    }

    var body: some View {
        let messages = MailPayloadAdapter.parse(payload, mapping: mapping)
        if messages.isEmpty {
            EmptyMailState()
        } else {
            let visible = Array(messages.prefix(maxRows))
            let overflow = messages.count - visible.count
            VStack(alignment: .leading, spacing: 8) {
                ForEach(visible) { row($0) }
                if overflow > 0 {
                    Text("+\(overflow) more")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.leading, 4)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func row(_ item: MailItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            avatar(item.sender)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.sender)
                        .font(.system(size: 13, weight: item.isRead ? .semibold : .bold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if item.isFlagged {
                        Text("URGENT")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.5)
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.orange))
                    }
                }
                Text(item.subject)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let date = item.date {
                Text(Self.relativeShort(date))
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }

    private func avatar(_ name: String) -> some View {
        Circle()
            .fill(theme.accentColor.opacity(0.18))
            .frame(width: 30, height: 30)
            .overlay(
                Text(Self.initials(name))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.accentColor)
            )
    }

    // MARK: Helpers

    private static func initials(_ name: String) -> String {
        let letters = name
            .split(whereSeparator: { $0 == " " || $0 == "." })
            .prefix(2)
            .compactMap { $0.first }
            .map(String.init)
        let joined = letters.joined().uppercased()
        return joined.isEmpty ? "?" : joined
    }

    /// compact "12m" / "2h" / "5d" relative label, like a mail client
    static func relativeShort(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 0 { return date.formatted(.dateTime.month().day()) }
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 604_800 { return "\(Int(seconds / 86_400))d" }
        return date.formatted(.dateTime.month().day())
    }
}

private struct EmptyMailState: View {
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 18))
                .foregroundColor(theme.tertiaryText)
            Text("No messages")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
