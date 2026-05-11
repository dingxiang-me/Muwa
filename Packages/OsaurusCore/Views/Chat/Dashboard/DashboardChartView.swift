//
//  DashboardChartView.swift
//  OsaurusCore
//

import AAInfographics
import AppKit
import SwiftUI

struct DashboardChartView: NSViewRepresentable {
    let spec: ChartSpec
    let theme: any ThemeProtocol

    func makeNSView(context: Context) -> AAChartView {
        let view = AAChartView()
        // suppress WKWebView's white flash before JS renders
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.aa_drawChartWithChartOptions(buildOptions())
        context.coordinator.lastSpec = spec
        return view
    }

    func updateNSView(_ nsView: AAChartView, context: Context) {
        // AAChartView's WebView reload is expensive; only redraw when spec actually changed
        guard context.coordinator.lastSpec != spec else { return }
        context.coordinator.lastSpec = spec
        nsView.aa_drawChartWithChartOptions(buildOptions())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastSpec: ChartSpec?
    }

    /// duplicated from `NativeChartView` to keep that file's `NSColor.hexString` fileprivate
    private static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    private func buildOptions() -> AAOptions {
        let bgHex = Self.hex(NSColor(theme.cardBackground))
        let textHex = Self.hex(NSColor(theme.primaryText))
        let gridHex = Self.hex(NSColor(theme.primaryBorder).withAlphaComponent(0.2))

        let isPie = spec.chartType == "pie"
        let seriesElements: [AASeriesElement] = spec.series.map { s in
            let element = AASeriesElement().name(s.name)
            if isPie, let cats = spec.categories {
                let paired: [Any] = s.data.enumerated().map { idx, v -> Any in
                    let label = idx < cats.count ? cats[idx] : "Slice \(idx + 1)"
                    return ["name": label, "y": v as Any? ?? NSNull()] as [String: Any]
                }
                return element.data(paired as [AnyObject])
            }
            return element.data(s.data.map { v -> Any in v.map { $0 as Any } ?? NSNull() } as [AnyObject])
        }

        let model = AAChartModel()
            .chartType(AAChartType(rawValue: spec.chartType) ?? .column)
            .backgroundColor(bgHex)
            .animationType(.easeInOutQuart)
            .animationDuration(400)
            .dataLabelsEnabled(spec.dataLabelsEnabled ?? false)
            .dataLabelsStyle(AAStyle().color(textHex).fontSize(9))
            .tooltipValueSuffix(spec.tooltipSuffix ?? "")
            // single-series cards don't need a legend
            .legendEnabled(spec.series.count > 1)
            .series(seriesElements)

        if let categories = spec.categories {
            model.categories(categories)
        }
        if let colors = spec.colorsTheme {
            model.colorsTheme(colors)
        }

        let options = model.aa_toAAOptions()
        let labelStyle = AAStyle().color(textHex).fontSize(9)
        options.xAxis?.labels(AALabels().style(labelStyle))
            .gridLineColor(gridHex)
            .lineColor(gridHex)
        options.yAxis?.labels(AALabels().style(labelStyle))
            .gridLineColor(gridHex)
            .lineColor(gridHex)
        options.legend?.itemStyle(AAStyle().color(textHex).fontSize(10).fontWeight(.regular))
        options.chart?.marginTop(8).marginBottom(28)
        return options
    }
}

// MARK: - Payload → ChartSpec

enum DashboardChartBuilder {
    /// returns nil for payloads with no plottable numeric data so the renderer can show "no data"
    static func buildSpec(
        payload: JSONValue,
        mapping: WidgetFieldMapping,
        title: String?
    ) -> ChartSpec? {
        // payload IS a ChartSpec (`{series, chartType, ...}`)
        if case .object(let dict) = payload,
            case .array = dict["series"] ?? .null
        {
            if let data = try? JSONEncoder().encode(payload),
                let spec = try? JSONDecoder().decode(ChartSpec.self, from: data)
            {
                return spec.normalized
            }
        }

        // array of `{x, y}` / `{title, value}` objects
        if case .array(let items) = payload {
            let objs: [[String: JSONValue]] = items.compactMap {
                if case .object(let d) = $0 { return d }
                return nil
            }
            if !objs.isEmpty {
                return specFromArrayOfObjects(objs, mapping: mapping, title: title)
            }
            // array of numbers → indexed series
            let nums = items.compactMap { value -> Double? in
                if case .number(let n) = value { return n }
                return nil
            }
            if !nums.isEmpty {
                let cats = (0 ..< nums.count).map { "\($0 + 1)" }
                return ChartSpec(
                    chartType: "column",
                    title: title,
                    categories: cats,
                    series: [ChartSeries(name: "Value", data: nums.map(Optional.some))]
                )
            }
        }
        return nil
    }

    private static func specFromArrayOfObjects(
        _ rows: [[String: JSONValue]],
        mapping: WidgetFieldMapping,
        title: String?
    ) -> ChartSpec? {
        let first = rows[0]
        let xKey =
            mapping.xKey
            ?? mapping.titleKey
            ?? first.keys.sorted().first(where: { isStringy(first[$0]) })
            ?? first.keys.sorted().first ?? "x"
        let yKey =
            mapping.yKey
            ?? mapping.valueKey
            ?? first.keys.sorted().first(where: { isNumericish(first[$0]) && $0 != xKey })
            ?? first.keys.sorted().first(where: { $0 != xKey })
            ?? "y"

        let categories: [String] = rows.map { row in
            switch row[xKey] {
            case .string(let s)?: return s
            case .number(let n)?: return formatChartNumber(n)
            case .bool(let b)?: return b ? "true" : "false"
            default: return "—"
            }
        }
        let data: [Double?] = rows.map { row in
            switch row[yKey] {
            case .number(let n)?: return n
            case .string(let s)?: return Double(s)
            default: return nil
            }
        }
        if data.allSatisfy({ $0 == nil }) { return nil }

        return ChartSpec(
            chartType: "column",
            title: title,
            categories: categories,
            series: [ChartSeries(name: yKey, data: data)]
        )
    }

    private static func isStringy(_ value: JSONValue?) -> Bool {
        if case .string = value ?? .null { return true }
        return false
    }

    private static func isNumericish(_ value: JSONValue?) -> Bool {
        switch value ?? .null {
        case .number: return true
        case .string(let s): return Double(s) != nil
        default: return false
        }
    }

    private static func formatChartNumber(_ n: Double) -> String {
        if n.rounded() == n && abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }
}
