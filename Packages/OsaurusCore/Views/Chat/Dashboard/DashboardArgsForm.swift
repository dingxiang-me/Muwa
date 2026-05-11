//
//  DashboardArgsForm.swift
//  OsaurusCore
//

import SwiftUI

// MARK: - Schema parsing

/// renders the JSON-Schema subset we care about: string (with enum), integer,
/// number, boolean, string-array — everything else falls back to a raw JSON field
struct ParsedProperty: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let kind: Kind
    let description: String?
    let required: Bool
    let defaultValue: JSONValue?

    enum Kind: Equatable {
        case string(enumValues: [String]?)
        case integer(minimum: Int?, maximum: Int?)
        case number
        case boolean
        case stringArray
        case unknown
    }
}

enum DashboardSchemaParser {
    /// returns nil when the schema isn't an object (caller shows "no arguments")
    static func parse(_ schema: JSONValue?) -> [ParsedProperty]? {
        guard let schema, case .object(let root) = schema else { return nil }
        guard case .object(let props) = root["properties"] ?? .null else {
            return []
        }
        var required: Set<String> = []
        if case .array(let arr) = root["required"] ?? .null {
            for entry in arr {
                if case .string(let s) = entry { required.insert(s) }
            }
        }
        var out: [ParsedProperty] = []
        for key in props.keys.sorted() {
            guard case .object(let propDict) = props[key] ?? .null else { continue }
            let kind = parseKind(propDict)
            let description: String?
            if case .string(let s) = propDict["description"] ?? .null { description = s } else { description = nil }
            out.append(
                ParsedProperty(
                    name: key,
                    kind: kind,
                    description: description,
                    required: required.contains(key),
                    defaultValue: propDict["default"]
                )
            )
        }
        return out
    }

    private static func parseKind(_ propDict: [String: JSONValue]) -> ParsedProperty.Kind {
        let typeStr: String
        if case .string(let s) = propDict["type"] ?? .null {
            typeStr = s
        } else {
            return .unknown
        }
        switch typeStr {
        case "string":
            if case .array(let arr) = propDict["enum"] ?? .null {
                let values = arr.compactMap { v -> String? in
                    if case .string(let s) = v { return s }
                    return nil
                }
                return .string(enumValues: values.isEmpty ? nil : values)
            }
            return .string(enumValues: nil)
        case "integer":
            return .integer(
                minimum: intFrom(propDict["minimum"]),
                maximum: intFrom(propDict["maximum"])
            )
        case "number":
            return .number
        case "boolean":
            return .boolean
        case "array":
            // only string-arrays get first-class treatment
            if case .object(let items) = propDict["items"] ?? .null,
                case .string(let itemType) = items["type"] ?? .null,
                itemType == "string"
            {
                return .stringArray
            }
            return .unknown
        default:
            return .unknown
        }
    }

    private static func intFrom(_ value: JSONValue?) -> Int? {
        guard case .number(let n) = value ?? .null else { return nil }
        return Int(n)
    }
}

// MARK: - View

struct DashboardArgsForm: View {
    @Environment(\.theme) private var theme
    let parameters: JSONValue?
    @Binding var arguments: JSONValue

    private var parsed: [ParsedProperty]? {
        DashboardSchemaParser.parse(parameters)
    }

    var body: some View {
        let props = parsed
        if let props {
            if props.isEmpty {
                emptyState("This tool takes no arguments.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(props) { prop in
                        propertyRow(prop)
                    }
                }
            }
        } else {
            emptyState("Tool has no parameter schema. Edit raw JSON below.")
            rawJSONEditor
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func propertyRow(_ prop: ParsedProperty) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(prop.name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                if prop.required {
                    Text("required")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.orange)
                }
                Spacer()
            }
            switch prop.kind {
            case .string(.some(let values)):
                enumPicker(prop, values: values)
            case .string(.none):
                stringField(prop)
            case .integer:
                numberField(prop, integerOnly: true)
            case .number:
                numberField(prop, integerOnly: false)
            case .boolean:
                booleanField(prop)
            case .stringArray:
                stringArrayField(prop)
            case .unknown:
                unknownField(prop)
            }
            if let desc = prop.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(3)
            }
        }
    }

    private func stringField(_ prop: ParsedProperty) -> some View {
        let binding = stringBinding(for: prop.name, defaultValue: prop.defaultValue)
        return TextField("", text: binding)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground)
            )
    }

    private func enumPicker(_ prop: ParsedProperty, values: [String]) -> some View {
        let binding = stringBinding(for: prop.name, defaultValue: prop.defaultValue)
        return Picker("", selection: binding) {
            ForEach(values, id: \.self) { v in
                Text(v).tag(v)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private func numberField(_ prop: ParsedProperty, integerOnly: Bool) -> some View {
        let binding = stringBinding(
            for: prop.name,
            defaultValue: prop.defaultValue,
            asNumberCoerced: integerOnly ? .integer : .number
        )
        return TextField(integerOnly ? "0" : "0.0", text: binding)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground)
            )
    }

    private func booleanField(_ prop: ParsedProperty) -> some View {
        let binding = Binding<Bool>(
            get: {
                if case .bool(let b) = currentArgument(prop.name) { return b }
                if case .bool(let b) = prop.defaultValue ?? .null { return b }
                return false
            },
            set: { newValue in
                setArgument(prop.name, value: .bool(newValue))
            }
        )
        return Toggle(isOn: binding) { EmptyView() }
            .toggleStyle(.switch)
            .labelsHidden()
    }

    private func stringArrayField(_ prop: ParsedProperty) -> some View {
        let binding = Binding<String>(
            get: {
                guard case .array(let arr) = currentArgument(prop.name) else { return "" }
                return arr.compactMap { v in
                    if case .string(let s) = v { return s }
                    return nil
                }.joined(separator: "\n")
            },
            set: { newValue in
                let parts = newValue
                    .split(whereSeparator: { $0.isNewline })
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                setArgument(prop.name, value: .array(parts.map { .string($0) }))
            }
        )
        return TextEditor(text: binding)
            .font(.system(size: 11, design: .monospaced))
            .frame(minHeight: 60, maxHeight: 120)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground)
            )
            .overlay(alignment: .topLeading) {
                Text("One value per line")
                    .font(.system(size: 9))
                    .foregroundColor(theme.tertiaryText)
                    .padding(8)
                    .allowsHitTesting(false)
                    .opacity(emptyArray(prop.name) ? 1 : 0)
            }
    }

    private func unknownField(_ prop: ParsedProperty) -> some View {
        let binding = Binding<String>(
            get: { jsonString(for: currentArgument(prop.name) ?? .null) ?? "" },
            set: { newValue in
                if let parsed = parseJSONString(newValue) {
                    setArgument(prop.name, value: parsed)
                } else {
                    setArgument(prop.name, value: .string(newValue))
                }
            }
        )
        return TextField("JSON value", text: binding)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground)
            )
    }

    // MARK: Raw JSON fallback

    private var rawJSONEditor: some View {
        let binding = Binding<String>(
            get: { jsonString(for: arguments) ?? "{}" },
            set: { newValue in
                if let parsed = parseJSONString(newValue) {
                    arguments = parsed
                }
            }
        )
        return TextEditor(text: binding)
            .font(.system(size: 11, design: .monospaced))
            .frame(minHeight: 80, maxHeight: 160)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground)
            )
    }

    private func emptyState(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Bindings

    private enum NumberKind { case integer, number }

    /// optionally coerces entered text into a typed JSONValue (integer/number)
    private func stringBinding(
        for name: String,
        defaultValue: JSONValue?,
        asNumberCoerced kind: NumberKind? = nil
    ) -> Binding<String> {
        Binding<String>(
            get: {
                if let value = currentArgument(name), case .null = value {
                    return ""
                } else if let value = currentArgument(name) {
                    return scalarText(value) ?? ""
                }
                return scalarText(defaultValue ?? .null) ?? ""
            },
            set: { newValue in
                if newValue.isEmpty {
                    clearArgument(name)
                    return
                }
                switch kind {
                case .integer:
                    if let n = Int(newValue) {
                        setArgument(name, value: .number(Double(n)))
                    } else {
                        setArgument(name, value: .string(newValue))
                    }
                case .number:
                    if let n = Double(newValue) {
                        setArgument(name, value: .number(n))
                    } else {
                        setArgument(name, value: .string(newValue))
                    }
                case nil:
                    setArgument(name, value: .string(newValue))
                }
            }
        )
    }

    private func currentArgument(_ key: String) -> JSONValue? {
        if case .object(let dict) = arguments { return dict[key] }
        return nil
    }

    private func setArgument(_ key: String, value: JSONValue) {
        var dict: [String: JSONValue] = {
            if case .object(let d) = arguments { return d }
            return [:]
        }()
        dict[key] = value
        arguments = .object(dict)
    }

    private func clearArgument(_ key: String) {
        guard case .object(var dict) = arguments else { return }
        dict.removeValue(forKey: key)
        arguments = .object(dict)
    }

    private func emptyArray(_ key: String) -> Bool {
        if case .array(let arr) = currentArgument(key) ?? .null { return arr.isEmpty }
        return true
    }

    private func scalarText(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s): return s
        case .number(let n):
            if n.rounded() == n && abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return nil
        case .array, .object: return nil
        }
    }

    private func jsonString(for value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
            let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    private func parseJSONString(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
