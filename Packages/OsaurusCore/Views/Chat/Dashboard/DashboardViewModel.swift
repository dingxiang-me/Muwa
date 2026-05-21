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
    /// buffered by the chat-side pin notification when the dashboard isn't mounted yet
    @Published var pendingPinRequest: DashboardPinRequest?

    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    /// per-widget refresh token; bumped on every refresh so slow calls can't overwrite newer results
    private var refreshTokens: [UUID: Int] = [:]
    private var scenePhase: ScenePhase = .active
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        widgets = DashboardStore.load()

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
        results[id] = .loading

        // calendar widgets always fetch the current week so day-tap filtering has data
        let effectiveArgs: JSONValue = widget.renderConfig.renderer == .calendar
            ? CalendarWeekArgs.rewrite(widget.arguments, mapping: widget.renderConfig.mapping)
            : widget.arguments
        let argumentsJSON = encodeArgs(effectiveArgs)
        do {
            let raw = try await ToolRegistry.shared.execute(
                name: widget.toolName,
                argumentsJSON: argumentsJSON
            )
            guard refreshTokens[id] == token else { return }
            results[id] = parseEnvelope(raw)
        } catch {
            guard refreshTokens[id] == token else { return }
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

    /// flip widgets whose tool was unregistered into an error state; don't delete them
    /// so the widget recovers automatically when the tool comes back
    private func reconcileAgainstRegistry() {
        let known = Set(ToolRegistry.shared.listTools().map { $0.name })
        for widget in widgets where !known.contains(widget.toolName) {
            results[widget.id] = .error(
                message: "Tool '\(widget.toolName)' is not currently available.",
                kind: "tool_not_found"
            )
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
