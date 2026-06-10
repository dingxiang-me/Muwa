//
//  WorkflowDatabaseTests.swift
//  osaurus
//
//  Unit tests for WorkflowDatabase: CRUD roundtrips, score formula,
//  event persistence, and schema creation.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowDatabaseTests {

    private func makeTempDB() throws -> WorkflowDatabase {
        let db = WorkflowDatabase()
        try db.openInMemory()
        return db
    }

    private func sampleWorkflow(
        id: String = UUID().uuidString,
        name: String = "test-workflow",
        toolsUsed: [String] = ["terminal"],
        parameters: [WorkflowParameter] = [],
        steps: [WorkflowStep] = [],
        body: String = "steps:\n  - tool: terminal\n    action: echo hello"
    ) -> Workflow {
        Workflow(
            id: id,
            name: name,
            description: "A test workflow",
            triggerText: "test trigger",
            body: body,
            source: WorkflowSource.user,
            sourceModel: "test-model",
            parameters: parameters,
            steps: steps,
            toolsUsed: toolsUsed,
            skillsUsed: [],
            tokenCount: 100
        )
    }

    // MARK: - Workflow CRUD

    @Test func insertAndLoadWorkflowRoundtrip() throws {
        let db = try makeTempDB()
        let workflow = sampleWorkflow()
        try db.insertWorkflow(workflow)

        let loaded = try db.loadWorkflow(id: workflow.id)
        #expect(loaded != nil)
        #expect(loaded?.id == workflow.id)
        #expect(loaded?.name == workflow.name)
        #expect(loaded?.description == workflow.description)
        #expect(loaded?.triggerText == workflow.triggerText)
        #expect(loaded?.body == workflow.body)
        #expect(loaded?.source == .user)
        #expect(loaded?.sourceModel == "test-model")
        #expect(loaded?.tier == .active)
        #expect(loaded?.toolsUsed == ["terminal"])
        #expect(loaded?.tokenCount == 100)
        #expect(loaded?.version == 1)
    }

    @Test func parametersAndStepsPersistAsJSON() throws {
        let db = try makeTempDB()
        let parameters = [
            WorkflowParameter(name: "path", type: .string, description: "File path", required: true),
            WorkflowParameter(name: "count", type: .number, description: "", required: false, defaultValue: "3"),
        ]
        let steps = [
            WorkflowStep.tool("terminal", argsTemplate: "{\"command\": \"cat {{params.path}}\"}"),
            WorkflowStep.guidance("Summarize the output for the user."),
        ]
        let workflow = sampleWorkflow(parameters: parameters, steps: steps)
        try db.insertWorkflow(workflow)

        let loaded = try db.loadWorkflow(id: workflow.id)
        #expect(loaded?.parameters == parameters)
        #expect(loaded?.steps == steps)
        #expect(loaded?.steps.first?.kind == .tool)
        #expect(loaded?.steps.last?.kind == .guidance)
    }

    @Test func updateWorkflowChangesPersisted() throws {
        let db = try makeTempDB()
        var workflow = sampleWorkflow()
        try db.insertWorkflow(workflow)

        workflow.name = "updated-name"
        workflow.body = "steps:\n  - tool: web_fetch\n    action: GET /health"
        workflow.toolsUsed = ["web_fetch"]
        workflow.steps = [WorkflowStep.tool("web_fetch")]
        workflow.version = 2
        try db.updateWorkflow(workflow)

        let loaded = try db.loadWorkflow(id: workflow.id)
        #expect(loaded?.name == "updated-name")
        #expect(loaded?.body.contains("web_fetch") == true)
        #expect(loaded?.toolsUsed == ["web_fetch"])
        #expect(loaded?.steps == [WorkflowStep.tool("web_fetch")])
        #expect(loaded?.version == 2)
    }

    @Test func deleteWorkflowRemovesFromDB() throws {
        let db = try makeTempDB()
        let workflow = sampleWorkflow()
        try db.insertWorkflow(workflow)
        #expect(try db.loadWorkflow(id: workflow.id) != nil)

        try db.deleteWorkflow(id: workflow.id)
        #expect(try db.loadWorkflow(id: workflow.id) == nil)
    }

    @Test func loadAllWorkflowsReturnsAll() throws {
        let db = try makeTempDB()
        try db.insertWorkflow(sampleWorkflow(id: "1", name: "w1"))
        try db.insertWorkflow(sampleWorkflow(id: "2", name: "w2"))
        try db.insertWorkflow(sampleWorkflow(id: "3", name: "w3"))

        let all = try db.loadAllWorkflows()
        #expect(all.count == 3)
    }

    @Test func loadWorkflowsByIdsReturnsMatching() throws {
        let db = try makeTempDB()
        try db.insertWorkflow(sampleWorkflow(id: "a", name: "alpha"))
        try db.insertWorkflow(sampleWorkflow(id: "b", name: "beta"))
        try db.insertWorkflow(sampleWorkflow(id: "c", name: "gamma"))

        let result = try db.loadWorkflowsByIds(["a", "c"])
        #expect(result.count == 2)
        let names = Set(result.map(\.name))
        #expect(names.contains("alpha"))
        #expect(names.contains("gamma"))
    }

    @Test func loadWorkflowsByIdsEmptyArrayReturnsEmpty() throws {
        let db = try makeTempDB()
        let result = try db.loadWorkflowsByIds([])
        #expect(result.isEmpty)
    }

    @Test func loadWorkflowNotFoundReturnsNil() throws {
        let db = try makeTempDB()
        #expect(try db.loadWorkflow(id: "nonexistent") == nil)
    }

    // MARK: - Events

    @Test func insertAndLoadEventsRoundtrip() throws {
        let db = try makeTempDB()
        let workflow = sampleWorkflow()
        try db.insertWorkflow(workflow)

        let loadedEvent = WorkflowEvent(workflowId: workflow.id, eventType: .loaded, agentId: "issue-1")
        try db.insertEvent(loadedEvent)

        let succeededEvent = WorkflowEvent(workflowId: workflow.id, eventType: .succeeded, modelUsed: "opus")
        try db.insertEvent(succeededEvent)

        let allEvents = try db.loadEvents(workflowId: workflow.id)
        #expect(allEvents.count == 2)

        let loadedOnly = try db.loadEvents(workflowId: workflow.id, ofType: .loaded)
        #expect(loadedOnly.count == 1)
        #expect(loadedOnly[0].agentId == "issue-1")

        let succeededOnly = try db.loadEvents(workflowId: workflow.id, ofType: .succeeded)
        #expect(succeededOnly.count == 1)
        #expect(succeededOnly[0].modelUsed == "opus")
    }

    // MARK: - Scores

    @Test func upsertAndLoadScoreRoundtrip() throws {
        let db = try makeTempDB()
        let workflow = sampleWorkflow()
        try db.insertWorkflow(workflow)

        var score = WorkflowScore(
            workflowId: workflow.id,
            timesLoaded: 10,
            timesSucceeded: 8,
            timesFailed: 2,
            successRate: 0.8,
            lastUsedAt: Date(),
            score: 0.75
        )
        try db.upsertScore(score)

        let loaded = try db.loadScore(workflowId: workflow.id)
        #expect(loaded != nil)
        #expect(loaded?.timesLoaded == 10)
        #expect(loaded?.timesSucceeded == 8)
        #expect(loaded?.timesFailed == 2)
        #expect(abs((loaded?.successRate ?? 0) - 0.8) < 0.001)

        score.timesSucceeded = 9
        score.successRate = 0.818
        try db.upsertScore(score)

        let updated = try db.loadScore(workflowId: workflow.id)
        #expect(updated?.timesSucceeded == 9)
    }

    @Test func insertWorkflowCreatesDefaultScore() throws {
        let db = try makeTempDB()
        let workflow = sampleWorkflow()
        try db.insertWorkflow(workflow)

        let score = try db.loadScore(workflowId: workflow.id)
        #expect(score != nil)
        #expect(score?.timesLoaded == 0)
        #expect(score?.timesSucceeded == 0)
        #expect(score?.score == 0.0)
    }

    // MARK: - Score Formula

    @Test func recalculateScoreFormula() {
        var score = WorkflowScore(
            workflowId: "test",
            timesLoaded: 10,
            timesSucceeded: 8,
            timesFailed: 2,
            lastUsedAt: Date().addingTimeInterval(-5 * 86400)
        )
        score.recalculate()

        let expectedSuccessRate = 8.0 / 10.0
        #expect(abs(score.successRate - expectedSuccessRate) < 0.001)

        let expectedRecency = 1.0 / (1.0 + 5.0 / 30.0)
        let expectedScore = expectedSuccessRate * expectedRecency
        #expect(abs(score.score - expectedScore) < 0.01)
    }

    @Test func recalculateScoreWithNoUses() {
        var score = WorkflowScore(workflowId: "test")
        score.recalculate()
        #expect(score.successRate == 0.0)
        #expect(score.score == 0.0)
    }

    @Test func recalculateScoreWithNoLastUsed() {
        var score = WorkflowScore(
            workflowId: "test",
            timesSucceeded: 5,
            timesFailed: 0,
            lastUsedAt: nil
        )
        score.recalculate()
        #expect(score.successRate == 1.0)
        let recency = 1.0 / (1.0 + 365.0 / 30.0)
        #expect(abs(score.score - recency) < 0.01)
    }

    // MARK: - Migrations

    @Test func openInMemoryCreatesSchema() throws {
        let db = try makeTempDB()

        try db.insertWorkflow(sampleWorkflow())
        let workflows = try db.loadAllWorkflows()
        #expect(workflows.count == 1)

        let event = WorkflowEvent(workflowId: workflows[0].id, eventType: .loaded)
        try db.insertEvent(event)
        let events = try db.loadEvents(workflowId: workflows[0].id)
        #expect(events.count == 1)

        let score = try db.loadScore(workflowId: workflows[0].id)
        #expect(score != nil)
    }

    // MARK: - Cascade Deletes

    @Test func deleteWorkflowCascadesToEventsAndScores() throws {
        let db = try makeTempDB()
        let workflow = sampleWorkflow()
        try db.insertWorkflow(workflow)
        try db.insertEvent(WorkflowEvent(workflowId: workflow.id, eventType: .loaded))
        try db.insertEvent(WorkflowEvent(workflowId: workflow.id, eventType: .succeeded))

        try db.deleteWorkflow(id: workflow.id)

        let events = try db.loadEvents(workflowId: workflow.id)
        #expect(events.isEmpty)

        let score = try db.loadScore(workflowId: workflow.id)
        #expect(score == nil)
    }

    // MARK: - JSON Array Storage

    @Test func toolsUsedPersistsAsJSON() throws {
        let db = try makeTempDB()
        let workflow = sampleWorkflow(toolsUsed: ["terminal", "web_fetch", "sandbox_exec"])
        try db.insertWorkflow(workflow)

        let loaded = try db.loadWorkflow(id: workflow.id)
        #expect(loaded?.toolsUsed == ["terminal", "web_fetch", "sandbox_exec"])
    }

    @Test func emptyToolsUsedPersists() throws {
        let db = try makeTempDB()
        let workflow = sampleWorkflow(toolsUsed: [])
        try db.insertWorkflow(workflow)

        let loaded = try db.loadWorkflow(id: workflow.id)
        #expect(loaded?.toolsUsed.isEmpty == true)
    }
}
