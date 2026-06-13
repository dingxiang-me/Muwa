//
//  AgentEntity.swift
//  Muwa
//
//  App Intents entity + query for Muwa agents. The query reads the live
//  agent list directly from disk via `AgentStore` (the app is unsandboxed and
//  shares `~/.muwa/`), so picker population works without a live server.
//

import AppIntents
import MuwaCore

/// A selectable Muwa agent, used by `RunAgentIntent`.
struct AgentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let defaultQuery = AgentQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// Reads the agent list from disk. Built-in agents are excluded here: the
/// built-in "Muwa" agent is reached through `AskMuwaIntent`, mirroring
/// `GET /agents`, which also omits built-ins.
struct AgentQuery: EntityQuery, EntityStringQuery {
    func entities(for ids: [AgentEntity.ID]) async throws -> [AgentEntity] {
        let wanted = Set(ids)
        return await loadCustomAgents().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AgentEntity] {
        await loadCustomAgents()
    }

    func entities(matching string: String) async throws -> [AgentEntity] {
        let needle = string.lowercased()
        return await loadCustomAgents().filter { $0.name.lowercased().contains(needle) }
    }

    private func loadCustomAgents() async -> [AgentEntity] {
        await MainActor.run {
            AgentStore.loadAll()
                .filter { !$0.isBuiltIn }
                .map { AgentEntity(id: $0.id.uuidString, name: $0.name) }
        }
    }
}
