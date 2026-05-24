//
//  DashboardBriefingBand.swift
//  OsaurusCore
//

import SwiftUI

struct DashboardBriefingBand: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var service = DashboardBriefingService.shared
    @State private var isHovered = false

    var body: some View {
        Group {
            switch service.state {
            case .idle, .hidden:
                EmptyView()
            case .loading:
                loadingBand
            case .ready(let segments):
                bandContainer { BriefingRenderer(payload: payloadFromSegments(segments)) }
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }

    private func bandContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            controls
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(theme.accentColor.opacity(0.18), lineWidth: 1)
        )
    }

    private var loadingBand: some View {
        bandContainer {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
                Text("Composing your briefing…")
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button {
                service.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(theme.cardBackground))
            }
            .buttonStyle(.plain)
            .help("Refresh briefing")

            Menu {
                Picker("Update frequency", selection: cadenceBinding) {
                    ForEach(BriefingCadence.allCases, id: \.self) { cadence in
                        Text(cadence.displayName).tag(cadence)
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(theme.cardBackground))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help("Briefing frequency: \(service.cadence.displayName)")
        }
        .opacity(isHovered ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private var cadenceBinding: Binding<BriefingCadence> {
        Binding(get: { service.cadence }, set: { service.cadence = $0 })
    }

    /// shoehorns parsed segments back into the `{segments: [...]}` shape `BriefingRenderer` expects.
    /// segments don't round-trip to JSON; we re-emit a minimal version sufficient for re-parsing.
    private func payloadFromSegments(_ segments: [BriefingSegment]) -> JSONValue {
        .object(["segments": .array(segments.map(Self.encode))])
    }

    private static func encode(_ segment: BriefingSegment) -> JSONValue {
        switch segment {
        case .text(let value):
            return .object(["type": .string("text"), "value": .string(value)])
        case .pill(let label, let tone):
            return .object([
                "type": .string("pill"),
                "label": .string(label),
                "tone": .string(tone.rawValue),
            ])
        case .avatar(let url, let label):
            return .object([
                "type": .string("avatar"),
                "url": url.map { .string($0.absoluteString) } ?? .null,
                "label": label.map { .string($0) } ?? .null,
            ])
        case .avatars(let urls, let max):
            return .object([
                "type": .string("avatars"),
                "urls": .array(urls.map { $0.map { .string($0.absoluteString) } ?? .null }),
                "max": .number(Double(max)),
            ])
        case .icon(let name, let tone):
            return .object([
                "type": .string("icon"),
                "name": .string(name),
                "tone": .string(tone.rawValue),
            ])
        case .count(let value, let label):
            return .object([
                "type": .string("count"),
                "value": .number(Double(value)),
                "label": label.map { .string($0) } ?? .null,
            ])
        case .dateChip(let date, let label):
            return .object([
                "type": .string("dateChip"),
                "iso": date.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
                "label": .string(label),
            ])
        }
    }
}
