//
//  ServerConfigurationStore.swift
//  Muwa
//
//  Persistence for ServerConfiguration
//

import Foundation

@MainActor
enum ServerConfigurationStore {
    /// When set, configuration reads/writes use this directory instead of the default path.
    static var overrideDirectory: URL?

    static func load() -> ServerConfiguration? {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            var configuration = try JSONDecoder().decode(ServerConfiguration.self, from: Data(contentsOf: url))
            if migrateLegacyImmediateIdleResidencyIfNeeded(&configuration) {
                save(configuration)
            }
            return configuration
        } catch {
            print("[Muwa] Failed to load ServerConfiguration: \(error)")
            return nil
        }
    }

    static func save(_ configuration: ServerConfiguration) {
        let url = configurationFileURL()
        MuwaPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: [.atomic])
        } catch {
            print("[Muwa] Failed to save ServerConfiguration: \(error)")
        }
    }

    private static func configurationFileURL() -> URL {
        if let dir = overrideDirectory {
            return dir.appendingPathComponent("server.json")
        }
        return MuwaPaths.resolvePath(new: MuwaPaths.serverConfigFile(), legacy: "ServerConfiguration.json")
    }

    private static func migrateLegacyImmediateIdleResidencyIfNeeded(
        _ configuration: inout ServerConfiguration
    ) -> Bool {
        let markerURL = idleResidencyWarmDefaultMigrationMarkerURL()
        guard configuration.modelIdleResidencyPolicy == .immediately,
            !FileManager.default.fileExists(atPath: markerURL.path)
        else {
            return false
        }

        configuration.modelIdleResidencyPolicy = .defaultWarm
        MuwaPaths.ensureExistsSilent(markerURL.deletingLastPathComponent())
        try? Data().write(to: markerURL, options: [.atomic])
        return true
    }

    private static func idleResidencyWarmDefaultMigrationMarkerURL() -> URL {
        configurationFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent(".model-idle-residency-warm-default-migrated")
    }
}
