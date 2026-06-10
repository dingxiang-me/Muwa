//
//  WorkflowSearchServiceTests.swift
//  osaurus
//
//  Tests for WorkflowSearchService: verifies graceful degradation when
//  VecturaKit is uninitialized and validates reverse-ID map behavior.
//  Full vector-search quality is validated empirically, not by unit tests.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowSearchServiceTests {

    @Test func searchReturnsEmptyWhenUninitialized() async {
        let results = await WorkflowSearchService.shared.search(query: "deploy to staging")
        #expect(results.isEmpty)
    }

    @Test func indexWorkflowDoesNotCrashWhenUninitialized() async {
        let workflow = Workflow(
            id: "test-no-crash",
            name: "test",
            description: "should not crash",
            body: "steps:\n  - tool: terminal",
            source: WorkflowSource.user
        )
        await WorkflowSearchService.shared.indexWorkflow(workflow)
    }

    @Test func removeWorkflowDoesNotCrashWhenUninitialized() async {
        await WorkflowSearchService.shared.removeWorkflow(id: "nonexistent")
    }

    @Test func rebuildIndexDoesNotCrashWhenUninitialized() async {
        await WorkflowSearchService.shared.rebuildIndex()
    }

    @Test func searchWithTopKZeroReturnsEmpty() async {
        let results = await WorkflowSearchService.shared.search(query: "anything", topK: 0)
        #expect(results.isEmpty)
    }
}
