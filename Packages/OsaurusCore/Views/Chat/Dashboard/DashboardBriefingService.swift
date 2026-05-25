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
        Self.log("calling CoreModelService.generate (dataBlock bytes=\(dataBlock.count))")

        let raw: String
        do {
            raw = try await CoreModelService.shared.generate(
                prompt: "Latest readings from the user's dashboard:\n\n\(dataBlock)\n\nCompose the briefing now.",
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
            let snippet = summarize(from: payload)
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

    /// Collapses arrays into `{count, sample}` so the model sees magnitude (and sibling
    /// scalars like `total` survive truncation) instead of a wall of rows that gets cut off
    /// mid-array — which previously hid counts from the briefing entirely.
    private static func summarize(from value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let arr):
            return [
                "count": arr.count,
                "sample": arr.prefix(3).map { summarize(from: $0) },
            ]
        case .object(let dict):
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = summarize(from: v) }
            return out
        }
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

        Segment types you may use:
          { "type": "text",      "value": "..." }                           — plain words
          { "type": "pill",      "label": "...", "tone": "success|warning|danger|accent|neutral" }
          { "type": "count",     "value": 5, "label": "unread comments" }   — bold number with trailing label
          { "type": "icon",      "name": "<SF Symbol>", "tone": "accent" }
          { "type": "dateChip",  "iso": "YYYY-MM-DD" }                      — calendar chip
        Use 2–6 segments total. Be concise, friendly, factual. Never invent numbers or names — only use what's in the data block.
        If the data is empty or unclear, return: {"segments":[]}
        """
}
