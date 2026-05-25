//
//  DashboardBriefingService.swift
//  OsaurusCore
//

import Combine
import Foundation
import SwiftUI

enum BriefingCadence: Int, CaseIterable, Codable {
    case manualOnly = 0
    case onEveryOpen = -1
    case every15min = 900
    case every30min = 1800
    case hourly = 3600

    var displayName: String {
        switch self {
        case .manualOnly: return "Only when I refresh"
        case .onEveryOpen: return "Every time I open the dashboard"
        case .every15min: return "Every 15 minutes"
        case .every30min: return "Every 30 minutes"
        case .hourly: return "Every hour"
        }
    }

    /// nil = no periodic timer (manual / on-open)
    var intervalSeconds: TimeInterval? {
        switch self {
        case .manualOnly, .onEveryOpen: return nil
        default: return TimeInterval(rawValue)
        }
    }
}

enum BriefingState {
    case idle
    case loading
    case ready([BriefingSegment])
    case hidden
}

@MainActor
final class DashboardBriefingService: ObservableObject {
    static let shared = DashboardBriefingService()

    @Published private(set) var state: BriefingState = .idle
    @Published var cadence: BriefingCadence {
        didSet {
            UserDefaults.standard.set(cadence.rawValue, forKey: Self.cadenceKey)
            scheduleNext()
        }
    }
    @Published private(set) var lastRefreshedAt: Date?
    /// in-flight composition cue (shown even when a previous briefing stays on screen)
    @Published private(set) var isRefreshing = false

    /// bumped per `runRefresh` so a superseded run's cleanup can't clear a newer run's spinner
    private var refreshGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var scheduledTask: Task<Void, Never>?
    private var dashboardVisible = false
    private var cancellables: Set<AnyCancellable> = []

    private static let cadenceKey = "dashboard.briefing.cadence"
    private static let logFilePath = "/tmp/osaurus-briefing.log"

    private static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        NSLog("[Briefing] \(message)")
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: logFilePath)
        if FileManager.default.fileExists(atPath: logFilePath) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url)
        }
    }

    private init() {
        // .object(forKey:) — not .integer — because manualOnly.rawValue is 0,
        // indistinguishable from "no key set" via the integer accessor
        let stored = (UserDefaults.standard.object(forKey: Self.cadenceKey) as? Int)
            .flatMap(BriefingCadence.init(rawValue:))
        self.cadence = stored ?? .every30min
        Self.log("init: cadence=\(cadence.displayName), logFile=\(Self.logFilePath)")
        // no cache rehydrate: composing is instant and deterministic, so we just recompute once
        // the dashboard appears and widgets have data (avoids showing a stale briefing)

        // when widget results land (often after the initial dashboard mount),
        // re-trigger if we're still waiting for data
        DashboardViewModel.shared.$results
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.handleResultsChanged() }
            .store(in: &cancellables)
    }

    private func handleResultsChanged() {
        guard dashboardVisible else { return }
        // only re-fire when we're actively waiting (loading with no data block yet);
        // a successful or hidden state means we've already made our decision this cycle
        guard case .loading = state else { return }
        let hasReadyData = DashboardViewModel.shared.results.values.contains {
            if case .success = $0 { return true }
            return false
        }
        guard hasReadyData else { return }
        refresh()
    }

    // MARK: - Lifecycle hooks

    func dashboardDidAppear() {
        dashboardVisible = true
        let shouldRefresh = shouldRefreshOnAppear
        Self.log("dashboardDidAppear: shouldRefresh=\(shouldRefresh), lastRefreshedAt=\(String(describing: lastRefreshedAt))")
        if shouldRefresh { refresh() }
        scheduleNext()
    }

    func dashboardDidDisappear() {
        Self.log("dashboardDidDisappear")
        dashboardVisible = false
        scheduledTask?.cancel()
        scheduledTask = nil
    }

    private var shouldRefreshOnAppear: Bool {
        switch cadence {
        case .manualOnly: return false
        case .onEveryOpen: return true
        default:
            guard let last = lastRefreshedAt, let interval = cadence.intervalSeconds else {
                return true  // never refreshed → fetch once
            }
            return Date().timeIntervalSince(last) >= interval
        }
    }

    // MARK: - Refresh

    func refresh() {
        Self.log("refresh() called")
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.runRefresh()
        }
    }

    private func runRefresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        defer { if generation == refreshGeneration { isRefreshing = false } }

        let widgets = DashboardViewModel.shared.widgets
        let results = DashboardViewModel.shared.results
        Self.log("runRefresh: widgets=\(widgets.count), results=\(results.count)")

        guard !widgets.isEmpty else {
            Self.log("no widgets pinned — hiding band")
            state = .hidden
            return
        }

        // suppress the loading flicker when we already have a cached briefing on screen
        if case .ready = state {} else { state = .loading }

        // any widget produced data yet? (else stay in .loading; the results observer re-fires us)
        let hasData = widgets.contains { w in
            if case .success = results[w.id] ?? .idle { return true }
            return false
        }
        guard hasData else {
            let statuses = widgets.map { w -> String in
                switch results[w.id] ?? .idle {
                case .idle: return "\(w.title)=idle"
                case .loading: return "\(w.title)=loading"
                case .success: return "\(w.title)=success"
                case .error(let m, _): return "\(w.title)=error(\(m.prefix(40)))"
                }
            }
            Self.log("no widget data yet — waiting: \(statuses.joined(separator: ", "))")
            return
        }

        // compose deterministically from what each widget displays: accurate counts/dates, clean
        // grammar, no model hallucinations (the local model couldn't follow the composition rules)
        let segments = Self.composeSegments(widgets: widgets, results: results)
        guard !segments.isEmpty else {
            Self.log("composed no segments — hiding band")
            state = .hidden
            return
        }
        Self.log("composed \(segments.count) segments — showing band")
        state = .ready(segments)
        lastRefreshedAt = Date()
    }

    // MARK: - Deterministic composer
    //
    // Builds the briefing segments directly from what each widget renders. This replaces the LLM
    // because the local model couldn't reliably follow the composition/grounding rules.

    private static func composeSegments(widgets: [DashboardWidget], results: [UUID: WidgetResult]) -> [BriefingSegment] {
        var countItems: [[BriefingSegment]] = []
        var eventItems: [[BriefingSegment]] = []

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        for widget in widgets {
            guard case let .success(payload, _) = results[widget.id] ?? .idle else { continue }
            let config = widget.renderConfig
            switch config.renderer {
            case .stat:
                let pair = statHeadline(payload: payload, mapping: config.mapping, caption: config.caption)
                if let n = Int(pair.value), let label = pair.label, !label.isEmpty {
                    countItems.append([.count(value: n, label: label)])
                }
                // non-integer / unlabeled stats are skipped — the briefing is a count/event glance

            case .list, .table:
                let summary = widgetDisplaySummary(
                    renderer: config.renderer, mapping: config.mapping, caption: nil, payload: payload
                )
                if let total = summary["totalItems"] as? Int, total > 0 {
                    countItems.append([.count(value: total, label: collectionNoun(payload))])
                }

            case .calendar:
                let events = CalendarPayloadAdapter.parse(payload, mapping: config.mapping)
                    .filter { cal.startOfDay(for: $0.start) >= today }
                    .prefix(3)
                for event in events {
                    eventItems.append(eventPhrase(event, today: today, calendar: cal))
                }

            default:
                break  // markdown/keyValue/chart/raw don't summarize into a one-line glance
            }
        }

        guard !countItems.isEmpty || !eventItems.isEmpty else { return [] }

        var segments: [BriefingSegment] = [.text("You have")]
        segments += joinItems(countItems, finalConnector: "and")
        if !eventItems.isEmpty {
            if !countItems.isEmpty { segments.append(.text("plus")) }
            segments += joinItems(eventItems, finalConnector: "and")
        }
        return segments
    }

    /// `pill(title)` + timing: a bare word for today/tomorrow, else "on" + a date chip (never both)
    private static func eventPhrase(_ event: CalendarEvent, today: Date, calendar: Calendar) -> [BriefingSegment] {
        let diff = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: event.start)).day ?? 0
        var phrase: [BriefingSegment] = [.pill(label: event.title, tone: .accent)]
        switch diff {
        case 0: phrase.append(.text("today"))
        case 1: phrase.append(.text("tomorrow"))
        default:
            phrase.append(.text("on"))
            phrase.append(.dateChip(date: event.start, label: ""))
        }
        return phrase
    }

    /// the noun a list/table counts (e.g. `{messages:[…]}` → "messages")
    private static func collectionNoun(_ payload: JSONValue) -> String {
        if case .object(let dict) = payload {
            for key in ["messages", "events", "results", "records", "entries", "items", "rows", "data"] {
                if case .array = dict[key] ?? .null { return key }
            }
        }
        return "items"
    }

    /// Joins phrases into grammatical English. Commas are baked onto a preceding text segment (the
    /// flow layout would otherwise float a lone comma); the final pair gets `finalConnector`.
    private static func joinItems(_ items: [[BriefingSegment]], finalConnector: String) -> [BriefingSegment] {
        var out: [BriefingSegment] = []
        for (i, item) in items.enumerated() {
            if i > 0 {
                let isLast = (i == items.count - 1)
                if isLast {
                    if items.count > 2, case .text(let t) = out[out.count - 1] {
                        out[out.count - 1] = .text(t + ",")
                    }
                    out.append(.text(finalConnector))
                } else if case .text(let t) = out[out.count - 1] {
                    out[out.count - 1] = .text(t + ",")
                } else {
                    out.append(.text("·"))  // prev ended in a chip/count — use a separator glyph
                }
            }
            out.append(contentsOf: item)
        }
        return out
    }

    // MARK: - Scheduling

    private func scheduleNext() {
        scheduledTask?.cancel()
        scheduledTask = nil
        guard dashboardVisible, let interval = cadence.intervalSeconds else { return }
        // never-refreshed → wait a full interval from now (NOT zero — the bug was
        // `?? interval` which made the delay collapse to 1s and spam the LLM)
        let elapsed = lastRefreshedAt.map { Date().timeIntervalSince($0) } ?? 0
        let delay = max(1, interval - elapsed)
        scheduledTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.runRefresh()
            await MainActor.run { self?.scheduleNext() }
        }
    }

}
