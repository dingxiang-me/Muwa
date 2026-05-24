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
    /// the tool being configured — lets specific fields populate a dropdown from a companion
    /// tool (e.g. `mailbox_path` is filled from `list_mailboxes`) instead of free text
    var toolName: String? = nil

    private var parsed: [ParsedProperty]? {
        DashboardSchemaParser.parse(parameters)
    }

    var body: some View {
        let props = parsed
        if let props {
            if props.isEmpty {
                emptyState("This tool takes no arguments.")
            } else {
                let required = props.filter { $0.required }
                let optional = props.filter { !$0.required }
                VStack(alignment: .leading, spacing: 22) {
                    if !required.isEmpty {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(required) { propertyRow($0) }
                        }
                    }
                    if !optional.isEmpty {
                        VStack(alignment: .leading, spacing: 18) {
                            sectionHeader("Optional")
                            ForEach(optional) { propertyRow($0) }
                        }
                    }
                }
            }
        } else {
            emptyState("Tool has no parameter schema. Edit raw JSON below.")
            rawJSONEditor
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(theme.secondaryText)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Rows

    @ViewBuilder
    private func propertyRow(_ prop: ParsedProperty) -> some View {
        if let provider = cascadingProvider(for: prop) {
            // cascading dropdown labels itself ("Account"/"Mailbox"), so the generic field
            // name is dropped — the sub-pickers carry their own required markers
            VStack(alignment: .leading, spacing: 6) {
                DynamicEnumField(
                    provider: provider,
                    value: stringBinding(for: prop.name, defaultValue: prop.defaultValue),
                    theme: theme,
                    required: prop.required
                ) {
                    stringField(prop)
                }
                description(prop)
            }
        } else if case .boolean = prop.kind {
            // booleans read more naturally as "label ............ toggle" on one line
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    nameLabel(prop)
                    Spacer()
                    booleanField(prop)
                }
                description(prop)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    nameLabel(prop)
                    Spacer()
                }
                switch prop.kind {
                case .string(.some(let values)):
                    enumPicker(prop, values: values)
                case .string(.none):
                    if let provider = dynamicProvider(for: prop.name) {
                        DynamicEnumField(
                            provider: provider,
                            value: stringBinding(for: prop.name, defaultValue: prop.defaultValue),
                            theme: theme,
                            required: prop.required
                        ) {
                            stringField(prop)
                        }
                    } else {
                        stringField(prop)
                    }
                case .integer:
                    numberField(prop, integerOnly: true)
                case .number:
                    numberField(prop, integerOnly: false)
                case .boolean:
                    EmptyView()  // handled in the branch above
                case .stringArray:
                    stringArrayField(prop)
                case .unknown:
                    unknownField(prop)
                }
                description(prop)
            }
        }
    }

    /// returns the provider only for a string field that opts into the cascading
    /// (account → mailbox) UI, which renders its own labels in place of the field name
    private func cascadingProvider(for prop: ParsedProperty) -> DynamicOptionsProvider? {
        guard case .string(.none) = prop.kind else { return nil }
        guard let provider = dynamicProvider(for: prop.name), provider.cascading else { return nil }
        return provider
    }

    /// friendlier field labels for the form only — the argument key sent to the tool is unchanged
    private static let fieldDisplayNames: [String: String] = [
        "mailbox_path": "mailbox"
    ]
    /// description overrides for fields whose schema text is too technical once we render a nicer control
    private static let fieldDescriptions: [String: String] = [
        "mailbox_path": "Pick the account, then the mailbox to show."
    ]

    @ViewBuilder
    private func nameLabel(_ prop: ParsedProperty) -> some View {
        Text(Self.fieldDisplayNames[prop.name] ?? prop.name)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundColor(theme.primaryText)
        if prop.required {
            Text("required")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private func description(_ prop: ParsedProperty) -> some View {
        let text = Self.fieldDescriptions[prop.name] ?? prop.description
        if let text, !text.isEmpty {
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(3)
        }
    }

    private func stringField(_ prop: ParsedProperty) -> some View {
        let binding = stringBinding(for: prop.name, defaultValue: prop.defaultValue)
        return TextField("", text: binding)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground)
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
            .font(.system(size: 14, design: .monospaced))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground)
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
            .font(.system(size: 13, design: .monospaced))
            .frame(minHeight: 60, maxHeight: 120)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground)
            )
            .overlay(alignment: .topLeading) {
                Text("One value per line")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .padding(10)
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
            .font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground)
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
            .font(.system(size: 13, design: .monospaced))
            .frame(minHeight: 80, maxHeight: 160)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground)
            )
    }

    // MARK: - Dynamic dropdowns

    /// describes how to populate a field's dropdown by running a companion tool and reading
    /// `valueKey` out of each object in the `arrayKey` array of its result
    struct DynamicOptionsProvider {
        let sourceTool: String
        let arrayKey: String
        let valueKey: String
        /// optional numeric field appended to each label as a badge (e.g. unread count)
        let badgeKey: String?
        /// when true, values shaped like "Account/Mailbox" are split into two cascading
        /// dropdowns (pick the account first, then the mailbox within it)
        let cascading: Bool
        /// in cascading mode, the result field that holds a human-friendly account label
        /// (e.g. the email address) so the account dropdown shows "you@work.com" rather than
        /// the ambiguous account name. Falls back to the account name when absent.
        let accountLabelKey: String?
    }

    /// field name → provider. Activated only when the source tool is actually registered,
    /// so the dropdown appears for users who have the relevant plugin and falls back to a
    /// plain text field otherwise.
    private static let dynamicProviders: [String: DynamicOptionsProvider] = [
        "mailbox_path": DynamicOptionsProvider(
            sourceTool: "list_mailboxes",
            arrayKey: "mailboxes",
            valueKey: "mailbox_path",
            badgeKey: "unread_count",
            cascading: true,
            accountLabelKey: "account_email"
        )
    ]

    private func dynamicProvider(for fieldName: String) -> DynamicOptionsProvider? {
        guard let provider = Self.dynamicProviders[fieldName] else { return nil }
        let available = ToolRegistry.shared.listTools().contains { $0.name == provider.sourceTool }
        return available ? provider : nil
    }

    private func emptyState(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundColor(theme.tertiaryText)
            Text(message)
                .font(.system(size: 13))
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

// MARK: - Dynamic dropdown field

/// Runs a companion tool (e.g. `list_mailboxes`) on appear and offers its results as a
/// dropdown. While loading it shows a spinner; if the call fails or yields nothing it
/// renders `fallback` (the plain text field) so the user is never blocked.
private struct DynamicEnumField<Fallback: View>: View {
    let provider: DashboardArgsForm.DynamicOptionsProvider
    @Binding var value: String
    let theme: ThemeProtocol
    /// shows a "required" marker on each cascading sub-picker's caption
    var required: Bool = false
    @ViewBuilder var fallback: () -> Fallback

    @State private var phase: Phase = .loading
    /// selected account in cascading mode; the mailbox dropdown filters to this
    @State private var account: String = ""

    private enum Phase: Equatable {
        case loading
        case ready([Option])
        case failed
    }

    /// one fetched option; `account` is the first path segment (used to build the path),
    /// `accountLabel` is what we display for it (email when available), `leaf` the remainder
    private struct Option: Hashable {
        let value: String
        let account: String
        let accountLabel: String
        let leaf: String
        let badge: Int?
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    Text("Loading options…")
                        .font(.system(size: 13))
                        .foregroundColor(theme.tertiaryText)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
            case .ready(let options) where !options.isEmpty:
                if provider.cascading {
                    cascadingPickers(options)
                } else {
                    flatPicker(options)
                }
            case .ready, .failed:
                fallback()
            }
        }
        .task { await load() }
    }

    // MARK: Cascading (account → mailbox)

    private func cascadingPickers(_ options: [Option]) -> some View {
        let accounts = orderedAccounts(options)
        let mailboxes = options.filter { $0.account == account }

        var accountOptions = accounts.map { (value: $0.name, label: $0.label) }
        var mailboxOptions = mailboxes.map { (value: $0.value, label: label(for: $0)) }
        // keep a saved value selectable even if it isn't in the fetched list
        if !account.isEmpty, !accounts.contains(where: { $0.name == account }) {
            accountOptions.insert((value: account, label: account), at: 0)
        }
        if !value.isEmpty, !mailboxes.contains(where: { $0.value == value }) {
            mailboxOptions.insert((value: value, label: leafLabel(of: value)), at: 0)
        }

        return VStack(alignment: .leading, spacing: 12) {
            labeledPicker("Account") {
                Picker("", selection: accountBinding(options)) {
                    ForEach(accountOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            labeledPicker("Mailbox") {
                Picker("", selection: $value) {
                    Text("Select…").tag("")
                    ForEach(mailboxOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    /// a caption above a picker ("Account" / "Mailbox"), with an optional required marker
    private func labeledPicker<Content: View>(
        _ caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(caption)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                if required {
                    Text("required")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// account selection: clears the mailbox when switching to a different account
    private func accountBinding(_ options: [Option]) -> Binding<String> {
        Binding(
            get: { account.isEmpty ? (options.first?.account ?? "") : account },
            set: { newAccount in
                account = newAccount
                if !value.hasPrefix(newAccount + "/") { value = "" }
            }
        )
    }

    /// distinct accounts in first-seen order; `name` builds the path, `label` is displayed
    private func orderedAccounts(_ options: [Option]) -> [(name: String, label: String)] {
        var seen = Set<String>()
        var out: [(name: String, label: String)] = []
        for opt in options where !seen.contains(opt.account) {
            seen.insert(opt.account)
            out.append((name: opt.account, label: opt.accountLabel))
        }
        return out
    }

    // MARK: Flat (single dropdown)

    private func flatPicker(_ options: [Option]) -> some View {
        var opts = options.map { (value: $0.value, label: fullLabel(for: $0)) }
        if !value.isEmpty, !options.contains(where: { $0.value == value }) {
            opts.insert((value: value, label: value), at: 0)
        }
        return Picker("", selection: $value) {
            Text("Select…").tag("")
            ForEach(opts, id: \.value) { opt in
                Text(opt.label).tag(opt.value)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    // MARK: Labels

    private func label(for opt: Option) -> String {
        var l = opt.leaf.replacingOccurrences(of: "/", with: " › ")
        if let badge = opt.badge, badge > 0 { l += "  (\(badge))" }
        return l
    }

    private func fullLabel(for opt: Option) -> String {
        var l = opt.value.replacingOccurrences(of: "/", with: " › ")
        if let badge = opt.badge, badge > 0 { l += "  (\(badge))" }
        return l
    }

    private func leafLabel(of fullPath: String) -> String {
        fullPath.split(separator: "/").dropFirst().joined(separator: " › ")
    }

    // MARK: Load

    private func load() async {
        guard
            let raw = try? await ToolRegistry.shared.execute(
                name: provider.sourceTool, argumentsJSON: "{}"
            ),
            !ToolEnvelope.isError(raw)
        else {
            phase = .failed
            return
        }

        // accept both an `ok:true` envelope ({result: {...}}) and the plugin's raw object
        let payload: Any? = ToolEnvelope.successPayload(raw) ?? jsonObject(raw)
        guard let dict = payload as? [String: Any],
            let array = dict[provider.arrayKey] as? [[String: Any]]
        else {
            phase = .failed
            return
        }

        let options: [Option] = array.compactMap { item in
            guard let v = item[provider.valueKey] as? String, !v.isEmpty else { return nil }
            let segments = v.split(separator: "/").map(String.init)
            guard let acct = segments.first else { return nil }
            let leaf = segments.dropFirst().joined(separator: "/")
            let badge = item[provider.badgeKey ?? ""] as? Int
            // prefer the email label; fall back to the account name when the plugin
            // doesn't supply one (older plugin builds)
            let labelRaw = (item[provider.accountLabelKey ?? ""] as? String) ?? ""
            let accountLabel = labelRaw.isEmpty ? acct : labelRaw
            return Option(
                value: v,
                account: acct,
                accountLabel: accountLabel,
                leaf: leaf.isEmpty ? acct : leaf,
                badge: badge
            )
        }

        // seed the account from a previously-saved value, else the first account
        if !value.isEmpty, let saved = value.split(separator: "/").first {
            account = String(saved)
        } else {
            account = options.first?.account ?? ""
        }

        phase = options.isEmpty ? .failed : .ready(options)
    }

    private func jsonObject(_ raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

