//
//  DashboardViewModel.swift
//  OsaurusCore
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class DashboardViewModel: ObservableObject {
    static let shared = DashboardViewModel()

    @Published private(set) var widgets: [DashboardWidget] = []
    @Published private(set) var results: [UUID: WidgetResult] = [:]
    /// widgets with an in-flight fetch — drives the per-card spinner without discarding shown data
    @Published private(set) var refreshing: Set<UUID> = []
    /// buffered by the chat-side pin notification when the dashboard isn't mounted yet
    @Published var pendingPinRequest: DashboardPinRequest?

    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    /// per-widget refresh token; bumped on every refresh so slow calls can't overwrite newer results
    private var refreshTokens: [UUID: Int] = [:]
    private var scenePhase: ScenePhase = .active
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Diagnostics

    private static let logFilePath = "/tmp/osaurus-dashboard.log"

    private static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        NSLog("[Dashboard] \(message)")
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

    private func isToolAvailable(_ name: String) -> Bool {
        ToolRegistry.shared.listTools().contains { $0.name == name }
    }

    private init() {
        widgets = DashboardStore.load()
        Self.log("init: loaded \(widgets.count) widget(s): \(widgets.map { "\($0.title)[\($0.toolName)]" }.joined(separator: ", "))")

        NotificationCenter.default.publisher(for: .dashboardPinRequested)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let request = DashboardPinRequest(notification: note) else { return }
                self?.pendingPinRequest = request
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .toolsListChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reconcileAgainstRegistry()
            }
            .store(in: &cancellables)

        for widget in widgets {
            scheduleIfNeeded(widget)
        }
        bootstrapInitialFetches()
    }

    /// On launch, plugin/MCP tools often aren't registered yet, so a manual (no-timer) widget
    /// would sit idle until the user refreshes by hand. Fetch the ones whose tool is already
    /// available; the rest are picked up by `reconcileAgainstRegistry` once `.toolsListChanged`
    /// fires as their plugin finishes registering.
    private func bootstrapInitialFetches() {
        for widget in widgets {
            let scheduled = (widget.refreshSeconds ?? 0) > 0
            if scheduled { continue }  // scheduleIfNeeded already fires an immediate refresh
            if isToolAvailable(widget.toolName) {
                Self.log("bootstrap: '\(widget.toolName)' available — initial fetch")
                Task { await refresh(id: widget.id) }
            } else {
                Self.log("bootstrap: '\(widget.toolName)' NOT yet registered — waiting for toolsListChanged")
            }
        }
    }

    // MARK: - Mutation

    func addWidget(_ widget: DashboardWidget) {
        widgets.append(widget)
        DashboardStore.save(widgets)
        // scheduleIfNeeded already kicks off an immediate refresh when a
        // timer is set — only fall back to a one-off otherwise, else two
        // permission prompts race each other.
        let known = Set(ToolRegistry.shared.listTools().map { $0.name })
        let scheduled = (widget.refreshSeconds ?? 0) > 0
        scheduleIfNeeded(widget)
        if known.contains(widget.toolName) && !scheduled {
            Task { await refresh(id: widget.id) }
        }
    }

    func removeWidget(id: UUID) {
        widgets.removeAll { $0.id == id }
        results.removeValue(forKey: id)
        refreshTokens.removeValue(forKey: id)
        refreshTasks[id]?.cancel()
        refreshTasks.removeValue(forKey: id)
        DashboardStore.save(widgets)
    }

    func moveWidget(id: UUID, before targetId: UUID?) {
        guard let sourceIdx = widgets.firstIndex(where: { $0.id == id }) else { return }
        let widget = widgets.remove(at: sourceIdx)
        if let targetId,
            let destIdx = widgets.firstIndex(where: { $0.id == targetId })
        {
            widgets.insert(widget, at: destIdx)
        } else {
            widgets.append(widget)
        }
        DashboardStore.save(widgets)
    }

    /// Moves `id` to occupy `targetId`'s slot, matching drag direction (dragging down lands the
    /// widget after the target; dragging up lands it before). Used by interactive reordering.
    func moveWidget(id: UUID, toIndexOf targetId: UUID) {
        guard let from = widgets.firstIndex(where: { $0.id == id }),
            let to = widgets.firstIndex(where: { $0.id == targetId }),
            from != to
        else { return }
        let widget = widgets.remove(at: from)
        if let t = widgets.firstIndex(where: { $0.id == targetId }) {
            widgets.insert(widget, at: from < to ? t + 1 : t)
        } else {
            widgets.insert(widget, at: min(to, widgets.count))
        }
        DashboardStore.save(widgets)
    }

    func updateWidget(_ widget: DashboardWidget) {
        guard let idx = widgets.firstIndex(where: { $0.id == widget.id }) else { return }
        widgets[idx] = widget
        DashboardStore.save(widgets)
        refreshTasks[widget.id]?.cancel()
        refreshTasks.removeValue(forKey: widget.id)
        let scheduled = (widget.refreshSeconds ?? 0) > 0
        scheduleIfNeeded(widget)
        if !scheduled {
            Task { await refresh(id: widget.id) }
        }
    }

    // MARK: - Scene phase

    func setScenePhase(_ phase: ScenePhase) {
        guard scenePhase != phase else { return }
        scenePhase = phase
        for widget in widgets {
            refreshTasks[widget.id]?.cancel()
            refreshTasks.removeValue(forKey: widget.id)
            scheduleIfNeeded(widget)
        }
    }

    // MARK: - Refresh

    func refresh(id: UUID) async {
        guard let widget = widgets.first(where: { $0.id == id }) else { return }
        let token = (refreshTokens[id] ?? 0) + 1
        refreshTokens[id] = token
        refreshing.insert(id)
        // clear the spinner only if a newer refresh hasn't taken over this widget
        defer { if refreshTokens[id] == token { refreshing.remove(id) } }
        // keep the last successful data on screen during a re-fetch; only show the empty
        // "loading" placeholder when there's nothing to show yet (first load / after error)
        if case .success = results[id] {} else { results[id] = .loading }

        // calendar widgets always fetch the current week so day-tap filtering has data
        let effectiveArgs: JSONValue = widget.renderConfig.renderer == .calendar
            ? CalendarWeekArgs.rewrite(widget.arguments, mapping: widget.renderConfig.mapping)
            : widget.arguments
        let argumentsJSON = encodeArgs(effectiveArgs)
        Self.log("refresh: '\(widget.toolName)' token=\(token) available=\(isToolAvailable(widget.toolName)) args=\(argumentsJSON.prefix(200))")
        do {
            let raw = try await ToolRegistry.shared.execute(
                name: widget.toolName,
                argumentsJSON: argumentsJSON
            )
            guard refreshTokens[id] == token else {
                Self.log("refresh: '\(widget.toolName)' token=\(token) stale — discarding")
                return
            }
            let parsed = parseEnvelope(raw)
            switch parsed {
            case .success: Self.log("refresh: '\(widget.toolName)' → success (\(raw.count) bytes)")
            case .error(let m, let k): Self.log("refresh: '\(widget.toolName)' → error kind=\(k ?? "nil") msg=\(m.prefix(120))")
            default: break
            }
            results[id] = parsed
        } catch {
            guard refreshTokens[id] == token else { return }
            Self.log("refresh: '\(widget.toolName)' threw: \(error.localizedDescription)")
            results[id] = .error(message: error.localizedDescription, kind: nil)
        }
    }

    func refreshAll() {
        for widget in widgets {
            Task { await refresh(id: widget.id) }
        }
    }

    private func scheduleIfNeeded(_ widget: DashboardWidget) {
        guard let interval = widget.refreshSeconds, interval > 0 else { return }
        if scenePhase != .active && !widget.refreshInBackground { return }

        let id = widget.id
        let nanos = UInt64(interval) * 1_000_000_000
        let task = Task { [weak self] in
            await self?.refresh(id: id)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                await self?.refresh(id: id)
            }
        }
        refreshTasks[id] = task
    }

    /// Reacts to the registry changing (plugins/MCP finishing registration, or being removed):
    /// - tool now available + widget has no good data yet (idle/error) → fetch it. This is what
    ///   makes plugin-backed widgets load on first launch and recover after the tool returns.
    /// - tool gone → flip to an error state but keep the widget so it self-heals next time.
    private func reconcileAgainstRegistry() {
        let known = Set(ToolRegistry.shared.listTools().map { $0.name })
        Self.log("reconcile: registry has \(known.count) tools; checking \(widgets.count) widget(s)")
        for widget in widgets {
            if known.contains(widget.toolName) {
                switch results[widget.id] ?? .idle {
                case .success, .loading:
                    break  // already have / fetching data — don't stomp it
                case .idle, .error:
                    Self.log("reconcile: '\(widget.toolName)' now available — refreshing")
                    Task { await refresh(id: widget.id) }
                }
            } else {
                Self.log("reconcile: '\(widget.toolName)' missing — marking error")
                results[widget.id] = .error(
                    message: "Tool '\(widget.toolName)' is not currently available.",
                    kind: "tool_not_found"
                )
            }
        }
    }

    private func parseEnvelope(_ raw: String) -> WidgetResult {
        if ToolEnvelope.isError(raw) {
            return .error(message: ToolEnvelope.failureMessage(raw), kind: extractKind(raw))
        }
        if ToolEnvelope.isSuccess(raw) {
            guard let payload = ToolEnvelope.successPayload(raw) else {
                return .success(.null, fetchedAt: Date())
            }
            return .success(jsonValue(from: payload), fetchedAt: Date())
        }
        if let data = raw.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        {
            return .success(jsonValue(from: parsed), fetchedAt: Date())
        }
        return .success(.string(raw), fetchedAt: Date())
    }

    private func extractKind(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict["kind"] as? String
    }

    private func encodeArgs(_ args: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(args), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }

    private func jsonValue(from any: Any) -> JSONValue {
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
}
