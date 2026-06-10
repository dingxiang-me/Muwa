//
//  WorkflowService.swift
//  osaurus
//
//  Orchestrator for the workflows subsystem: CRUD, scoring, dependency
//  extraction (structured steps first, YAML body as fallback).
//

import Foundation
import os

// MARK: - Errors

enum WorkflowServiceError: Error, LocalizedError, Equatable {
    case workflowNotFound(String)

    var errorDescription: String? {
        switch self {
        case .workflowNotFound(let id): return "Workflow not found: \(id)"
        }
    }
}

// MARK: - WorkflowService

public actor WorkflowService {
    public static let shared = WorkflowService()

    private let db = WorkflowDatabase.shared

    private init() {}

    // MARK: - CRUD

    public func create(
        name: String,
        description: String,
        triggerText: String? = nil,
        body: String,
        source: WorkflowSource,
        sourceModel: String? = nil,
        parameters: [WorkflowParameter] = [],
        steps: [WorkflowStep] = []
    ) async throws -> Workflow {
        let toolsUsed = deriveToolIds(steps: steps, body: body)
        let skillsUsed = deriveSkillIds(steps: steps, body: body)
        let tokenCount = TokenEstimator.estimate(body)

        let workflow = Workflow(
            name: name,
            description: description,
            triggerText: triggerText,
            body: body,
            source: source,
            sourceModel: sourceModel,
            parameters: parameters,
            steps: steps,
            toolsUsed: toolsUsed,
            skillsUsed: skillsUsed,
            tokenCount: tokenCount
        )

        try db.insertWorkflow(workflow)
        await WorkflowSearchService.shared.indexWorkflow(workflow)

        WorkflowLogger.service.info(
            "Created workflow '\(name)' (id: \(workflow.id), tools: \(toolsUsed.count))"
        )
        return workflow
    }

    public func update(_ workflow: Workflow) async throws {
        var updated = workflow
        updated.toolsUsed = deriveToolIds(steps: workflow.steps, body: workflow.body)
        updated.skillsUsed = deriveSkillIds(steps: workflow.steps, body: workflow.body)
        try db.updateWorkflow(updated)
        await WorkflowSearchService.shared.indexWorkflow(updated)
        WorkflowLogger.service.info("Updated workflow '\(updated.name)' to v\(updated.version)")
    }

    public func delete(id: String) async throws {
        try db.deleteWorkflow(id: id)
        await WorkflowSearchService.shared.removeWorkflow(id: id)
        WorkflowLogger.service.info("Deleted workflow \(id)")
    }

    public func load(id: String) throws -> Workflow? {
        try db.loadWorkflow(id: id)
    }

    public func loadAll() throws -> [Workflow] {
        try db.loadAllWorkflows()
    }

    public func loadScore(workflowId: String) throws -> WorkflowScore? {
        try db.loadScore(workflowId: workflowId)
    }

    // MARK: - Scoring

    public func reportOutcome(
        workflowId: String,
        outcome: WorkflowEventType,
        modelUsed: String? = nil,
        agentId: String? = nil,
        notes: String? = nil
    ) throws {
        let event = WorkflowEvent(
            workflowId: workflowId,
            eventType: outcome,
            modelUsed: modelUsed,
            agentId: agentId,
            notes: notes
        )
        try db.insertEvent(event)

        var score = try db.loadScore(workflowId: workflowId) ?? WorkflowScore(workflowId: workflowId)

        switch outcome {
        case .loaded:
            score.timesLoaded += 1
            score.lastUsedAt = Date()
        case .succeeded:
            score.timesSucceeded += 1
            score.lastUsedAt = Date()
        case .failed:
            score.timesFailed += 1
            score.lastUsedAt = Date()
        }

        score.recalculate()
        try db.upsertScore(score)
    }

    // MARK: - Dependency Extraction

    /// Tools referenced by the workflow. Structured steps are
    /// authoritative when present; legacy/body-only workflows fall back
    /// to scraping `tool:` lines out of the YAML body.
    func deriveToolIds(steps: [WorkflowStep], body: String) -> [String] {
        if !steps.isEmpty {
            var tools: [String] = []
            var seen = Set<String>()
            for step in steps {
                if let name = step.toolName, !name.isEmpty, seen.insert(name).inserted {
                    tools.append(name)
                }
            }
            return tools
        }
        return extractToolIds(from: body)
    }

    /// Skills referenced by the workflow (`skillContext` on steps, or
    /// `skill_context:` lines in a legacy YAML body).
    func deriveSkillIds(steps: [WorkflowStep], body: String) -> [String] {
        if !steps.isEmpty {
            var skills: [String] = []
            var seen = Set<String>()
            for step in steps {
                if let skill = step.skillContext, !skill.isEmpty, seen.insert(skill).inserted {
                    skills.append(skill)
                }
            }
            return skills
        }
        return extractSkillIds(from: body)
    }

    // MARK: - YAML Extraction (legacy body-only workflows)

    func extractToolIds(from yaml: String) -> [String] {
        var tools: [String] = []
        var seen = Set<String>()
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("tool:") || trimmed.hasPrefix("- tool:") {
                let value =
                    trimmed
                    .replacingOccurrences(of: "- tool:", with: "")
                    .replacingOccurrences(of: "tool:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty, !seen.contains(value) {
                    tools.append(value)
                    seen.insert(value)
                }
            }
        }
        return tools
    }

    func extractSkillIds(from yaml: String) -> [String] {
        var skills: [String] = []
        var seen = Set<String>()
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("skill_context:") {
                let value =
                    trimmed
                    .replacingOccurrences(of: "skill_context:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty, !seen.contains(value) {
                    skills.append(value)
                    seen.insert(value)
                }
            }
        }
        return skills
    }

}
