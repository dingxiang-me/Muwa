//
//  RemoteAgentStore.swift
//  Muwa
//
//  Per-remote-agent JSON files at `~/.muwa/remote-agents/<id>.json`.
//  Mirrors `AgentStore`'s shape so future migrations can reuse the same
//  patterns.
//

import Foundation

@MainActor
public enum RemoteAgentStore {

    public static func loadAll() -> [RemoteAgent] {
        let directory = MuwaPaths.remoteAgents()
        MuwaPaths.ensureExistsSilent(directory)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var result: [RemoteAgent] = []
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let agent = try decoder.decode(RemoteAgent.self, from: data)
                result.append(agent)
            } catch {
                print("[Muwa] Failed to load remote agent from \(file.lastPathComponent): \(error)")
            }
        }
        return result.sorted { $0.pairedAt > $1.pairedAt }
    }

    public static func save(_ agent: RemoteAgent) {
        let url = fileURL(for: agent.id)
        MuwaPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(agent).write(to: url, options: [.atomic])
        } catch {
            print("[Muwa] Failed to save remote agent \(agent.id): \(error)")
        }
    }

    @discardableResult
    public static func delete(id: UUID) -> Bool {
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
            return true
        } catch {
            print("[Muwa] Failed to delete remote agent \(id): \(error)")
            return false
        }
    }

    public static func exists(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: id).path)
    }

    private static func fileURL(for id: UUID) -> URL {
        MuwaPaths.remoteAgents().appendingPathComponent("\(id.uuidString).json")
    }
}
