//
//  WorkflowSearchColdStartTests.swift
//  osaurusTests
//
//  Pins the cold-start discoverability invariant for the workflows lane.
//
//  Regression from a live session (2026-06-10): with exactly ONE saved
//  workflow, `capabilities_discover` returned nothing for a near-verbatim
//  query. The lane used VecturaKit hybrid scoring (`hybridWeight: 0.5`),
//  and BM25's Robertson IDF `log((N-df+0.5)/(df+0.5))` is negative for
//  every matching term at N=1 — clamped to 0 by the combiner, capping the
//  hybrid score at `cosine/2` (measured 0.223 vs the 0.25 lane floor).
//  Every user's workflow corpus starts at N=1, so the feature was least
//  discoverable exactly when the first workflow was saved. The lane is now
//  vector-only; these tests run the production VecturaConfig against a
//  single-document index to keep it that way.
//

import Foundation
import Testing
import VecturaKit

@testable import OsaurusCore

struct WorkflowSearchColdStartTests {

    // Index text shape mirrors `WorkflowSearchService.buildIndexText`
    // (name with underscores expanded, description, trigger text) for the
    // workflow saved in the live session.
    private static let singleWorkflowIndexText =
        "family office report to pdf Reads a family office PDF report (Addepar format), "
        + "extracts portfolio snapshot/allocation/holdings/performance/risk data, and "
        + "generates a clean 1-page summary PDF. Create 1-page family office summary PDF from the report"

    private func makeSingleDocDB() async throws -> VecturaKit {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-cold-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = try WorkflowSearchService.makeVecturaConfig(directoryURL: dir)
        let db = try await VecturaKit(config: config, embedder: EmbeddingService.sharedEmbedder)
        _ = try await db.addDocument(text: Self.singleWorkflowIndexText, id: UUID())
        return db
    }

    /// The live-miss queries must clear the lane floor against a
    /// single-document corpus. If scoring ever regresses to something
    /// corpus-size dependent (hybrid BM25, score normalization, etc.),
    /// this catches it at the exact corpus size every new user has.
    @Test func singleSavedWorkflowIsDiscoverable() async throws {
        let db = try await makeSingleDocDB()
        let floor = CapabilitySearch.minimumRelevanceScoreWorkflows

        for query in [
            "osaurus workflow family office report",  // live miss: 0.223 hybrid, 0.446 cosine
            "family office report",
            "generate a report for family office",
        ] {
            let results = try await db.search(query: .text(query), numResults: 5, threshold: 0.0)
            let top = try #require(results.first, "no results at all for '\(query)'")
            #expect(
                top.score >= floor,
                "cold-start miss: '\(query)' scored \(top.score) below lane floor \(floor)"
            )
        }
    }

    /// Vector-only scoring roughly doubles raw scores vs the old clamped
    /// hybrid; the floor must still reject chit-chat so discover keeps
    /// abstaining (mirrors `Suites/CapabilitySearch/workflow-abstain.json`).
    @Test func chitChatStaysBelowFloorOnSingleDocCorpus() async throws {
        let db = try await makeSingleDocDB()
        let floor = CapabilitySearch.minimumRelevanceScoreWorkflows

        for query in ["thanks, that's perfect", "good morning!"] {
            let results = try await db.search(query: .text(query), numResults: 5, threshold: 0.0)
            let topScore = results.first?.score ?? 0
            #expect(
                topScore < floor,
                "abstain regression: '\(query)' scored \(topScore) at/above lane floor \(floor)"
            )
        }
    }
}
