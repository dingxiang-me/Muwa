//
//  DashboardWidget.swift
//  OsaurusCore
//

import Foundation

enum WidgetRenderer: String, Codable, Sendable, CaseIterable {
    case stat
    case keyValue
    case list
    case table
    case markdown
    case chart
    case raw
}

struct WidgetFieldMapping: Codable, Equatable, Sendable {
    var titleKey: String?
    var subtitleKey: String?
    var valueKey: String?
    var xKey: String?
    var yKey: String?

    init(
        titleKey: String? = nil,
        subtitleKey: String? = nil,
        valueKey: String? = nil,
        xKey: String? = nil,
        yKey: String? = nil
    ) {
        self.titleKey = titleKey
        self.subtitleKey = subtitleKey
        self.valueKey = valueKey
        self.xKey = xKey
        self.yKey = yKey
    }
}

struct RenderConfig: Codable, Equatable, Sendable {
    var renderer: WidgetRenderer
    var mapping: WidgetFieldMapping

    init(renderer: WidgetRenderer, mapping: WidgetFieldMapping = WidgetFieldMapping()) {
        self.renderer = renderer
        self.mapping = mapping
    }
}

enum WidgetSize: String, Codable, Sendable, CaseIterable {
    case small
    case medium
    case large
}

struct DashboardWidget: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var toolName: String
    var arguments: JSONValue
    var refreshSeconds: Int?
    /// when false, timer pauses while app is backgrounded
    var refreshInBackground: Bool
    /// nil = `Agent.defaultId`
    var agentId: UUID?
    var renderConfig: RenderConfig
    var size: WidgetSize

    init(
        id: UUID = UUID(),
        title: String,
        toolName: String,
        arguments: JSONValue = .object([:]),
        refreshSeconds: Int? = nil,
        refreshInBackground: Bool = false,
        agentId: UUID? = nil,
        renderConfig: RenderConfig,
        size: WidgetSize = .medium
    ) {
        self.id = id
        self.title = title
        self.toolName = toolName
        self.arguments = arguments
        self.refreshSeconds = refreshSeconds
        self.refreshInBackground = refreshInBackground
        self.agentId = agentId
        self.renderConfig = renderConfig
        self.size = size
    }
}

enum WidgetResult: Equatable, Sendable {
    case idle
    case loading
    case success(JSONValue, fetchedAt: Date)
    case error(message: String, kind: String?)
}
