//
//  DashboardStore.swift
//  OsaurusCore
//

import Foundation

enum DashboardStore {
    private static var fileURL: URL {
        OsaurusPaths.root().appendingPathComponent("dashboard.json", isDirectory: false)
    }

    static func load() -> [DashboardWidget] {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(StoredEnvelope.self, from: data).widgets
        } catch {
            // quarantine corrupt files so the next save doesn't clobber them
            NSLog("[Dashboard] Failed to decode \(url.path): \(error). Quarantining file.")
            let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
    }

    static func save(_ widgets: [DashboardWidget]) {
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.root())
        let envelope = StoredEnvelope(version: 1, widgets: widgets)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(envelope)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[Dashboard] Failed to save widgets: \(error)")
        }
    }

    private struct StoredEnvelope: Codable {
        let version: Int
        let widgets: [DashboardWidget]
    }
}
