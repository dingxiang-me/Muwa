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

    private var refreshTask: Task<Void, Never>?
    private var scheduledTask: Task<Void, Never>?
    private var dashboardVisible = false
    private var cancellables: Set<AnyCancellable> = []

    private static let cadenceKey = "dashboard.briefing.cadence"
    private static let cacheKey = "dashboard.briefing.cachedRaw"
    private static let cacheTimestampKey = "dashboard.briefing.cachedAt"
    private static let logFilePath = "/tmp/osaurus-briefing.log"

    /// YYYY-MM-DD for grounding the model on today's date (matches dateChip's `iso` format)
    private nonisolated(unsafe) static let isoDay: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

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
        rehydrateFromCache()

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

        let dataBlock = Self.encodeWidgetData(widgets: widgets, results: results)
        guard !dataBlock.isEmpty else {
            // widgets exist but none have a successful result yet — stay in .loading,
            // results-observer will re-trigger us once data lands
            let statuses = widgets.map { w -> String in
                let r = results[w.id] ?? .idle
                switch r {
                case .idle: return "\(w.title)=idle"
                case .loading: return "\(w.title)=loading"
                case .success: return "\(w.title)=success"
                case .error(let m, _): return "\(w.title)=error(\(m.prefix(40)))"
                }
            }
            Self.log("data block empty — widgets not ready: \(statuses.joined(separator: ", "))")
            return
        }
        Self.log("calling CoreModelService.generate (dataBlock bytes=\(dataBlock.count))\n\(dataBlock)")

        let raw: String
        do {
            let today = Date().formatted(date: .complete, time: .omitted)
            raw = try await CoreModelService.shared.generate(
                prompt: "Today is \(today) (ISO: \(Self.isoDay.string(from: Date()))).\n\nLatest readings from the user's dashboard:\n\n\(dataBlock)\n\nCompose the briefing now.",
                systemPrompt: Self.systemPrompt,
                temperature: 0.6,
                maxTokens: 600,
                timeout: 25
            )
            Self.log("LLM returned \(raw.count) chars: \(raw.prefix(200))")
        } catch {
            Self.log("CoreModelService.generate FAILED: \(error)")
            state = .hidden
            return
        }

        guard let segments = Self.parseSegments(raw), !segments.isEmpty else {
            Self.log("parse FAILED; raw=\(raw.prefix(400))")
            state = .hidden
            return
        }
        Self.log("parsed \(segments.count) segments — showing band")

        state = .ready(segments)
        lastRefreshedAt = Date()
        UserDefaults.standard.set(raw, forKey: Self.cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cacheTimestampKey)
    }

    private func rehydrateFromCache() {
        guard let raw = UserDefaults.standard.string(forKey: Self.cacheKey),
            let segments = Self.parseSegments(raw),
            !segments.isEmpty
        else { return }
        state = .ready(segments)
        let ts = UserDefaults.standard.double(forKey: Self.cacheTimestampKey)
        if ts > 0 { lastRefreshedAt = Date(timeIntervalSince1970: ts) }
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

    // MARK: - Data block

    /// compresses each pinned widget's latest result into a tiny JSON dump the LLM can summarize
    private static func encodeWidgetData(widgets: [DashboardWidget], results: [UUID: WidgetResult]) -> String {
        var entries: [[String: Any]] = []
        for widget in widgets {
            guard case let .success(payload, fetchedAt) = results[widget.id] ?? .idle else { continue }
            // describe what the CARD shows (headline value, list items, event dates) rather than
            // re-summarizing the raw payload — keeps the briefing in lockstep with the widgets
            let snippet = widgetDisplaySummary(
                renderer: widget.renderConfig.renderer,
                mapping: widget.renderConfig.mapping,
                caption: widget.renderConfig.caption,
                payload: payload
            )
            let truncated = truncate(snippet, maxChars: 600)
            entries.append([
                "name": widget.title,
                "tool": widget.toolName,
                "fetchedAt": ISO8601DateFormatter().string(from: fetchedAt),
                "data": truncated,
            ])
        }
        guard !entries.isEmpty else { return "" }
        guard let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted]),
            let s = String(data: data, encoding: .utf8)
        else { return "" }
        return s
    }

    /// hard cap on serialized snippet length so a large payload (e.g. a long event list) doesn't
    /// blow out the prompt budget; the model only needs flavor, not the full document
    private static func truncate(_ value: Any, maxChars: Int) -> Any {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
            let s = String(data: data, encoding: .utf8)
        else { return value }
        if s.count <= maxChars { return value }
        let endIndex = s.index(s.startIndex, offsetBy: maxChars)
        return String(s[..<endIndex]) + "…"
    }

    // MARK: - Parsing

    private static func parseSegments(_ raw: String) -> [BriefingSegment]? {
        guard let json = extractJSONObject(from: raw),
            let data = json.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        let value = jsonValue(from: parsed)
        let segments = BriefingSegment.parse(value)
        return segments.isEmpty ? nil : segments
    }

    private static func jsonValue(from any: Any) -> JSONValue {
        if any is NSNull { return .null }
        if let b = any as? Bool { return .bool(b) }
        if let n = any as? NSNumber { return .number(n.doubleValue) }
        if let s = any as? String { return .string(s) }
        if let arr = any as? [Any] { return .array(arr.map(jsonValue(from:))) }
        if let dict = any as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (k, v) in dict { out[k] = jsonValue(from: v) }
            return .object(out)
        }
        return .null
    }

    /// pulls the first balanced top-level `{...}` from a chatty LLM response (handles preambles + code fences)
    private static func extractJSONObject(from raw: String) -> String? {
        guard let firstBrace = raw.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var end: String.Index?
        for idx in raw.indices[firstBrace...] {
            let ch = raw[idx]
            if escape { escape = false; continue }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { end = raw.index(after: idx); break }
            }
        }
        guard let end else { return nil }
        return String(raw[firstBrace..<end])
    }

    // MARK: - Prompt

    private static let systemPrompt = """
        You compose a one-sentence personal briefing for the user's dashboard, returned as JSON segments.

        Output EXACTLY this shape — a single JSON object, no Markdown, no code fences, no prose:
        {
          "segments": [
            { "type": "text", "value": "..." },
            ...
          ]
        }

        Segment types:
          { "type": "text",      "value": "..." }                           — plain connective words ONLY
          { "type": "pill",      "label": "...", "tone": "success|warning|danger|accent|neutral" }  — a status/label
          { "type": "count",     "value": 5, "label": "unread comments" }   — a number + what it counts
          { "type": "icon",      "name": "<SF Symbol>", "tone": "accent" }   — a small leading glyph
          { "type": "dateChip",  "iso": "YYYY-MM-DD" }                       — a calendar date

        CRITICAL — the briefing's value comes from rich segments, not text. The text segments are
        only the quiet glue between highlights. So:
          • Every NUMBER must be a `count` segment — never write a digit inside a `text` value.
          • Every DATE/deadline must be a `dateChip` — never write a date inside text.
          • Every STATUS / state / category (e.g. "In Progress", "Overdue", "Done") must be a `pill`
            with a fitting tone (success=good, warning=attention, danger=problem, accent=neutral-highlight).
          • Lead a clause with an `icon` when a relevant SF Symbol fits (e.g. "envelope.fill" for mail,
            "calendar" for events, "bubble.left.fill" for messages).

        GROUNDING — accuracy matters more than richness. Violations make the briefing useless.
        Each entry in the data block describes exactly what ONE widget shows the user:
          • `displays: "a single headline value"` → use its `value` and `label` VERBATIM as one count
            segment (value + label). Do not recompute or relabel it.
          • `displays: "a list"/"a table"` → its `totalItems` is the true magnitude; `items` is only a
            preview of the first rows. Report `totalItems`, never the length of `items`.
          • `displays: "a calendar"` → each event has a `title`, a `date`, and a `when` field that is
            ALREADY COMPUTED for you ("today", "tomorrow", "in N days", or "past"). Phrase timing using
            `when` verbatim — NEVER compute it yourself and NEVER say "today" unless `when` is "today".
            Emit the event's `date` in its `dateChip`. Skip events whose `when` is "past".
          • Use ONLY numbers, names, labels, and dates present in the data. Do NOT invent qualifiers
            like "unread", "new", or "overdue" unless the data explicitly carries that state.

        Begin the briefing with a text segment whose value is exactly "You have".

        The example below shows STRUCTURE ONLY. Never copy its placeholder names, numbers, or dates —
        they are fake. Use only the real data block.
          example data: a list {totalItems: 7}, a calendar {events:[{title:"Q3 Planning",date:"2031-02-14",when:"in 3 days"}]}
          {"segments":[
            {"type":"text","value":"You have"},
            {"type":"count","value":7,"label":"open tasks, and"},
            {"type":"pill","label":"Q3 Planning","tone":"accent"},
            {"type":"text","value":"in 3 days on"},
            {"type":"dateChip","iso":"2031-02-14"}
          ]}

        Use 3–8 segments. Be concise, friendly, factual. If the data is empty or unclear, return {"segments":[]}.
        """
}
