//
//  WorkflowSearchService.swift
//  osaurus
//
//  Wraps VecturaKit for hybrid search (BM25 + vector) over workflows.
//  Falls back gracefully when VecturaKit is unavailable.
//

import CryptoKit
import Foundation
import VecturaKit
import os

/// Diagnostic snapshot for `WorkflowSearchService.searchWithDiagnostic`.
/// Mirrors `ToolSearchDiagnostic` shape so the env-flag log path in
/// `CapabilitySearch.search` can format all three uniformly.
public struct WorkflowSearchDiagnostic: Sendable {
    public struct Hit: Sendable {
        public let name: String
        public let score: Float
        public init(name: String, score: Float) {
            self.name = name
            self.score = score
        }
    }

    public let indexedWorkflowCount: Int
    public let rawHits: [Hit]
    public let acceptedHits: [Hit]
    public let threshold: Float

    public init(indexedWorkflowCount: Int, rawHits: [Hit], acceptedHits: [Hit], threshold: Float) {
        self.indexedWorkflowCount = indexedWorkflowCount
        self.rawHits = rawHits
        self.acceptedHits = acceptedHits
        self.threshold = threshold
    }
}

public actor WorkflowSearchService {
    public static let shared = WorkflowSearchService()

    private static let defaultSearchThreshold: Float = 0.10

    private var vectorDB: VecturaKit?
    private var isInitialized = false

    private init() {}

    // MARK: - Initialization

    public func initialize() async {
        guard !isInitialized else { return }

        let storageDir = OsaurusPaths.workflows().appendingPathComponent("vectura", isDirectory: true)

        for attempt in 1 ... 2 {
            do {
                OsaurusPaths.ensureExistsSilent(storageDir)

                let config = try VecturaConfig(
                    name: "osaurus-workflows",
                    directoryURL: storageDir,
                    dimension: EmbeddingService.embeddingDimension,
                    searchOptions: VecturaConfig.SearchOptions(
                        defaultNumResults: 10,
                        minThreshold: 0.3,
                        hybridWeight: 0.5,
                        k1: 1.2,
                        b: 0.75
                    ),
                    memoryStrategy: .automatic()
                )

                vectorDB = try await VecturaKit(config: config, embedder: EmbeddingService.sharedEmbedder)
                isInitialized = true
                rehydrateReverseIdMap()
                WorkflowLogger.search.info("VecturaKit initialized successfully for workflows")
                break
            } catch {
                if attempt == 1 {
                    WorkflowLogger.search.warning(
                        "VecturaKit init failed for workflows, deleting storage to recover: \(error)"
                    )
                    try? FileManager.default.removeItem(at: storageDir)
                } else {
                    WorkflowLogger.search.error("VecturaKit init failed for workflows (search unavailable): \(error)")
                    vectorDB = nil
                }
            }
        }
    }

    /// See `ToolSearchService.rehydrateReverseIdMap` for the rationale.
    /// Without this, search returns empty until `rebuildIndex()`
    /// completes, leaving `capabilities_discover` unable to surface
    /// installed workflows until the index repopulates.
    private func rehydrateReverseIdMap() {
        guard let workflows = try? WorkflowDatabase.shared.loadAllWorkflows() else { return }
        for workflow in workflows {
            _ = deterministicUUID(for: workflow.id)
        }
        WorkflowLogger.search.info("Workflow reverse-id map rehydrated with \(workflows.count) entries")
    }

    // MARK: - Indexing

    public func indexWorkflow(_ workflow: Workflow) async {
        guard let db = vectorDB else { return }
        do {
            let toolDescs = Self.loadToolDescriptions()
            let id = deterministicUUID(for: workflow.id)
            let text = buildIndexText(for: workflow, toolDescriptions: toolDescs)
            _ = try await db.addDocument(text: text, id: id)
        } catch {
            WorkflowLogger.search.error("Failed to index workflow \(workflow.id): \(error)")
        }
    }

    public func removeWorkflow(id: String) async {
        guard let db = vectorDB else { return }
        do {
            let uuid = deterministicUUID(for: id)
            try await db.deleteDocuments(ids: [uuid])
            reverseIdMap.removeValue(forKey: uuid.uuidString)
        } catch {
            WorkflowLogger.search.error("Failed to remove workflow \(id) from index: \(error)")
        }
    }

    // MARK: - Search

    public func search(
        query: String,
        topK: Int = 10,
        threshold: Float? = nil
    ) async -> [WorkflowSearchResult] {
        guard topK > 0 else { return [] }
        guard let db = vectorDB else { return [] }
        do {
            let fetchCount = topK * 3
            let results = try await db.search(
                query: .text(query),
                numResults: fetchCount,
                threshold: threshold ?? Self.defaultSearchThreshold
            )

            let scoreMap = Dictionary(
                results.map { ($0.id.uuidString, Float($0.score)) },
                uniquingKeysWith: { first, _ in first }
            )

            let workflowIds = results.compactMap { reverseIdMap[$0.id.uuidString] }

            let workflows = try WorkflowDatabase.shared.loadWorkflowsByIds(workflowIds)
            let scores = try workflowIds.compactMap { try WorkflowDatabase.shared.loadScore(workflowId: $0) }
            let scoreByWorkflow = Dictionary(
                scores.map { ($0.workflowId, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            return Array(
                workflows.compactMap { workflow -> WorkflowSearchResult? in
                    let uuid = deterministicUUID(for: workflow.id)
                    guard let searchScore = scoreMap[uuid.uuidString] else { return nil }
                    let workflowScore = scoreByWorkflow[workflow.id]?.score ?? 0.0
                    return WorkflowSearchResult(workflow: workflow, searchScore: searchScore, score: workflowScore)
                }
                .sorted { $0.searchScore > $1.searchScore }
                .prefix(topK)
            )
        } catch {
            WorkflowLogger.search.error("Workflow search failed: \(error)")
            return []
        }
    }

    /// Diagnostic-capturing search. See `ToolSearchService.searchWithDiagnostic`
    /// for rationale — runs the underlying query twice (raw + accepted)
    /// to surface the embedder's pre-threshold candidate set without
    /// changing the production single-call hot path.
    public func searchWithDiagnostic(
        query: String,
        topK: Int,
        threshold: Float
    ) async -> (results: [WorkflowSearchResult], diagnostic: WorkflowSearchDiagnostic) {
        let indexedCount = (try? WorkflowDatabase.shared.loadAllWorkflows().count) ?? 0
        let raw = await search(query: query, topK: topK, threshold: 0.0)
        let accepted = await search(query: query, topK: topK, threshold: threshold)
        let diagnostic = WorkflowSearchDiagnostic(
            indexedWorkflowCount: indexedCount,
            rawHits: raw.map { WorkflowSearchDiagnostic.Hit(name: $0.workflow.name, score: $0.searchScore) },
            acceptedHits: accepted.map { WorkflowSearchDiagnostic.Hit(name: $0.workflow.name, score: $0.searchScore) },
            threshold: threshold
        )
        return (accepted, diagnostic)
    }

    // MARK: - Rebuild

    public func rebuildIndex() async {
        guard let db = vectorDB else { return }
        do {
            try await db.reset()
            reverseIdMap.removeAll()

            let toolDescs = Self.loadToolDescriptions()

            let workflows = try WorkflowDatabase.shared.loadAllWorkflows()
            var texts: [String] = []
            var ids: [UUID] = []
            texts.reserveCapacity(workflows.count)
            ids.reserveCapacity(workflows.count)
            for workflow in workflows {
                let id = deterministicUUID(for: workflow.id)
                texts.append(buildIndexText(for: workflow, toolDescriptions: toolDescs))
                ids.append(id)
            }
            if !texts.isEmpty {
                _ = try await db.addDocuments(texts: texts, ids: ids)
            }
            WorkflowLogger.search.info("Workflow index rebuilt with \(workflows.count) workflows")
        } catch {
            WorkflowLogger.search.error("Failed to rebuild workflow index: \(error)")
        }
    }

    // MARK: - Helpers

    private var reverseIdMap: [String: String] = [:]

    private func buildIndexText(for workflow: Workflow, toolDescriptions: [String: String] = [:]) -> String {
        var text = workflow.description
        if let trigger = workflow.triggerText, !trigger.isEmpty {
            text += " " + trigger
        }
        for toolName in workflow.toolsUsed {
            text += " \(toolName)"
            if let desc = toolDescriptions[toolName] {
                text += " \(desc)"
            }
        }
        return text
    }

    private static func loadToolDescriptions() -> [String: String] {
        do {
            return try ToolDatabase.shared.loadAllEntries()
                .reduce(into: [String: String]()) { $0[$1.name] = $1.description }
        } catch {
            return [:]
        }
    }

    private func deterministicUUID(for workflowId: String) -> UUID {
        let hash = SHA256.hash(data: Data("workflow:\(workflowId)".utf8))
        let bytes = Array(hash)
        let uuid = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
        reverseIdMap[uuid.uuidString] = workflowId
        return uuid
    }
}
