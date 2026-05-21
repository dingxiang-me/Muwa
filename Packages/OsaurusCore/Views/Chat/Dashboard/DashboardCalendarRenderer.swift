//
//  DashboardCalendarRenderer.swift
//  OsaurusCore
//

import SwiftUI

// MARK: - Model

struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let start: Date
    let end: Date?

    var isAllDay: Bool {
        guard let end else { return false }
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: start)
        let durationHours = end.timeIntervalSince(start) / 3600
        return comps.hour == 0 && comps.minute == 0 && durationHours >= 23
    }
}

// MARK: - Adapter

enum CalendarPayloadAdapter {
    /// resolves common field names + mapping overrides; tolerates both `[event]` and `{events:[...]}`
    static func parse(_ payload: JSONValue, mapping: WidgetFieldMapping) -> [CalendarEvent] {
        let items: [JSONValue] = {
            if case .array(let arr) = payload { return arr }
            if case .object(let dict) = payload {
                for key in ["events", "items", "results", "data"] {
                    if case .array(let arr) = dict[key] ?? .null { return arr }
                }
            }
            return []
        }()

        return items.enumerated().compactMap { (idx, raw) -> CalendarEvent? in
            guard case .object(let dict) = raw else { return nil }
            guard let start = readDate(dict, keys: [mapping.startKey, "start", "start_date", "startDate", "starts_at", "begin", "date"]) else {
                return nil
            }
            let end = readDate(dict, keys: [mapping.endKey, "end", "end_date", "endDate", "ends_at", "finish"])
            let title = readString(dict, keys: [mapping.titleKey, "title", "summary", "name", "subject"]) ?? "Untitled"
            let subtitle = readString(dict, keys: [mapping.subtitleKey, "location", "notes", "description", "calendar"])
            let id = readString(dict, keys: ["id", "uid", "event_id"]) ?? "\(idx)"
            return CalendarEvent(id: id, title: title, subtitle: subtitle, start: start, end: end)
        }
        .sorted { $0.start < $1.start }
    }

    private static func readString(_ dict: [String: JSONValue], keys: [String?]) -> String? {
        for key in keys.compactMap({ $0 }) {
            if case .string(let s) = dict[key] ?? .null, !s.isEmpty { return s }
        }
        return nil
    }

    private static func readDate(_ dict: [String: JSONValue], keys: [String?]) -> Date? {
        for key in keys.compactMap({ $0 }) {
            guard let value = dict[key] else { continue }
            // accepts {dateTime: "..."}, ISO strings, or raw timestamps
            switch value {
            case .string(let s):
                if let d = parseDateString(s) { return d }
            case .number(let n):
                // seconds vs ms heuristic
                let interval = n > 1_000_000_000_000 ? n / 1000 : n
                return Date(timeIntervalSince1970: interval)
            case .object(let nested):
                if case .string(let s) = nested["dateTime"] ?? nested["date"] ?? .null {
                    if let d = parseDateString(s) { return d }
                }
            default: break
            }
        }
        return nil
    }

    private static func parseDateString(_ s: String) -> Date? {
        if let d = isoFull.date(from: s) { return d }
        if let d = isoDate.date(from: s) { return d }
        return nil
    }

    nonisolated(unsafe) private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Refresh-time arg rewriting

enum CalendarWeekArgs {
    /// rewrites the configured (or default) start/end keys to span the current week,
    /// so a single fetch covers all 7 days the strip exposes
    static func rewrite(_ args: JSONValue, mapping: WidgetFieldMapping) -> JSONValue {
        let startKey = mapping.startKey ?? "fromDate"
        let endKey = mapping.endKey ?? "toDate"
        let (start, end) = currentWeekBounds()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var dict: [String: JSONValue] = {
            if case .object(let d) = args { return d }
            return [:]
        }()
        dict[startKey] = .string(formatter.string(from: start))
        dict[endKey] = .string(formatter.string(from: end))
        return .object(dict)
    }

    private static func currentWeekBounds() -> (Date, Date) {
        var cal = Calendar.current
        cal.firstWeekday = 2 // Monday
        let today = cal.startOfDay(for: Date())
        guard let interval = cal.dateInterval(of: .weekOfYear, for: today) else {
            return (today, today.addingTimeInterval(7 * 86400))
        }
        return (interval.start, interval.end)
    }
}

// MARK: - View

struct CalendarRendererView: View {
    @Environment(\.theme) private var theme
    let payload: JSONValue
    let mapping: WidgetFieldMapping

    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    private var events: [CalendarEvent] {
        CalendarPayloadAdapter.parse(payload, mapping: mapping)
    }

    var body: some View {
        let weekDays = currentWeek()
        let today = Calendar.current.startOfDay(for: Date())
        let dayEvents = events.filter {
            Calendar.current.isDate($0.start, inSameDayAs: selectedDay)
        }

        VStack(alignment: .leading, spacing: 14) {
            weekStrip(days: weekDays, today: today)
            if dayEvents.isEmpty {
                emptyState
            } else {
                eventsList(dayEvents)
            }
        }
    }

    // MARK: Week strip

    private func weekStrip(days: [Date], today: Date) -> some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in
                dayChip(
                    day,
                    isToday: Calendar.current.isDate(day, inSameDayAs: today),
                    isSelected: Calendar.current.isDate(day, inSameDayAs: selectedDay)
                )
            }
        }
    }

    private func dayChip(_ day: Date, isToday: Bool, isSelected: Bool) -> some View {
        let weekday = day.formatted(.dateTime.weekday(.abbreviated)).uppercased()
        let dayNum = Calendar.current.component(.day, from: day)
        let filled = isToday
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedDay = Calendar.current.startOfDay(for: day)
            }
        } label: {
            VStack(spacing: 2) {
                Text(weekday)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(filled ? theme.primaryBackground : theme.tertiaryText)
                Text("\(dayNum)")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(filled ? theme.primaryBackground : theme.primaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(filled ? theme.primaryText : theme.secondaryBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected && !filled ? theme.accentColor : theme.cardBorder.opacity(filled ? 0 : 0.5),
                        lineWidth: isSelected && !filled ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: Events list

    private func eventsList(_ items: [CalendarEvent]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, event in
                eventRow(event)
                if idx < items.count - 1 {
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        let now = Date()
        let isHappening = event.start <= now && (event.end ?? event.start.addingTimeInterval(1800)) > now
        return HStack(alignment: .top, spacing: 14) {
            timeColumn(event, isHappening: isHappening)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                if let subtitle = event.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Circle()
                .fill(theme.tertiaryText.opacity(0.5))
                .frame(width: 5, height: 5)
                .padding(.top, 6)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func timeColumn(_ event: CalendarEvent, isHappening: Bool) -> some View {
        if event.isAllDay {
            Text("ALL DAY")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
        } else if isHappening {
            HStack(spacing: 4) {
                Text("NOW")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.accentColor)
                Text("·")
                    .foregroundColor(theme.tertiaryText)
                Text(event.start.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
        } else {
            Text(event.start.formatted(.dateTime.hour().minute()))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 14))
                .foregroundColor(theme.tertiaryText)
            Text("Nothing scheduled today")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    // MARK: Week helper

    /// Mon → Sun for the week containing today, respecting the user's locale first-weekday
    private func currentWeek() -> [Date] {
        var cal = Calendar.current
        cal.firstWeekday = 2 // Monday
        let today = cal.startOfDay(for: Date())
        guard let interval = cal.dateInterval(of: .weekOfYear, for: today) else {
            return [today]
        }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: interval.start) }
    }
}
