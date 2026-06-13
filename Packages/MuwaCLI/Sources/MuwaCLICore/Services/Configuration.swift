//
//  Configuration.swift
//  Muwa
//
//  Service for reading CLI configuration including server port and tools directory paths.
//

import Foundation
import MuwaRepository

public struct Configuration {
    /// Root data directory for Muwa (`~/.muwa/`)
    public static func root() -> URL {
        ToolsPaths.root()
    }

    public static func resolveConfiguredPort() -> Int? {
        if let env = ProcessInfo.processInfo.environment["OSU_PORT"], let p = Int(env) {
            return p
        }

        let fm = FileManager.default
        let root = root()

        // Check ~/.muwa/config/server.json first.
        let candidates: [URL] = [
            root.appendingPathComponent("config/server.json"),
            root.appendingPathComponent("ServerConfiguration.json"),
        ]

        guard let configURL = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            return nil
        }

        struct PartialConfig: Decodable { let port: Int? }
        do {
            let data = try Data(contentsOf: configURL)
            let cfg = try JSONDecoder().decode(PartialConfig.self, from: data)
            return cfg.port
        } catch {
            return nil
        }
    }

    public static func toolsRootDirectory() -> URL {
        ToolsPaths.toolsRootDirectory()
    }
}
