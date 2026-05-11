//
//  DashboardInference.swift
//  OsaurusCore
//

import Foundation

enum DashboardInference {

    static func inferRenderConfig(from value: JSONValue) -> RenderConfig {
        switch value {
        case .null:
            return RenderConfig(renderer: .raw)
        case .string:
            return RenderConfig(renderer: .markdown)
        case .number, .bool:
            return RenderConfig(renderer: .stat)
        case .object(let dict):
            return inferFromObject(dict)
        case .array(let arr):
            return inferFromArray(arr)
        }
    }

    private static func inferFromObject(_ dict: [String: JSONValue]) -> RenderConfig {
        // unwrap `{result: ...}`-style single-key envelopes one level
        if dict.count == 1, let inner = dict.values.first {
            switch inner {
            case .array, .object:
                return inferRenderConfig(from: inner)
            default:
                break
            }
        }

        let numericKey = dict.first(where: {
            if case .number = $0.value { return true }
            return false
        })?.key
        let labelKey = dict.first(where: {
            if case .string = $0.value { return true }
            return false
        })?.key
        if dict.count <= 2, let valueKey = numericKey {
            return RenderConfig(
                renderer: .stat,
                mapping: WidgetFieldMapping(titleKey: labelKey, valueKey: valueKey)
            )
        }

        if dict.values.allSatisfy({ isScalar($0) }) {
            return RenderConfig(renderer: .keyValue)
        }
        return RenderConfig(renderer: .raw)
    }

    private static func inferFromArray(_ arr: [JSONValue]) -> RenderConfig {
        if arr.isEmpty {
            return RenderConfig(renderer: .list)
        }

        if arr.allSatisfy({ if case .string = $0 { return true } else { return false } }) {
            return RenderConfig(renderer: .list)
        }

        if arr.allSatisfy({ if case .number = $0 { return true } else { return false } }) {
            return RenderConfig(renderer: .list)
        }

        guard
            let first = arr.first,
            case .object(let firstObj) = first,
            arr.allSatisfy({ if case .object = $0 { return true } else { return false } })
        else {
            return RenderConfig(renderer: .raw)
        }

        let keys = Set(firstObj.keys)

        if keys == Set(["x", "y"]) {
            return RenderConfig(
                renderer: .chart,
                mapping: WidgetFieldMapping(xKey: "x", yKey: "y")
            )
        }

        let titleKey = preferredTitleKey(in: firstObj)
        let subtitleKey = preferredSubtitleKey(in: firstObj, excluding: titleKey)

        if firstObj.count <= 2 {
            return RenderConfig(
                renderer: .list,
                mapping: WidgetFieldMapping(titleKey: titleKey, subtitleKey: subtitleKey)
            )
        }
        return RenderConfig(
            renderer: .table,
            mapping: WidgetFieldMapping(titleKey: titleKey, subtitleKey: subtitleKey)
        )
    }

    static func preferredTitleKey(in obj: [String: JSONValue]) -> String? {
        let preferred = ["title", "name", "summary", "subject", "label"]
        for key in preferred where obj[key].map(isStringy) == true {
            return key
        }
        return obj.keys.sorted().first(where: { obj[$0].map(isStringy) == true })
    }

    static func preferredSubtitleKey(
        in obj: [String: JSONValue],
        excluding titleKey: String?
    ) -> String? {
        let preferred = ["subtitle", "description", "detail", "when", "date", "start"]
        for key in preferred where key != titleKey && obj[key].map(isStringy) == true {
            return key
        }
        let candidates = obj.keys.sorted().filter { $0 != titleKey }
        return candidates.first(where: { obj[$0].map(isStringy) == true })
    }

    private static func isScalar(_ value: JSONValue) -> Bool {
        switch value {
        case .string, .number, .bool, .null: return true
        case .array, .object: return false
        }
    }

    private static func isStringy(_ value: JSONValue) -> Bool {
        switch value {
        case .string, .number, .bool: return true
        case .null, .array, .object: return false
        }
    }
}
