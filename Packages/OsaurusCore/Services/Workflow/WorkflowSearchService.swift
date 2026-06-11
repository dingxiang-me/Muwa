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

    /// Version of the `buildIndexText` shape. Bump whenever the indexed
    /// text changes (v2 added the workflow name) so existing installs
    /// rebuild on next launch instead of searching stale embeddings.
    private static let indexSchemaVersion = 2

    private var vectorDB: VecturaKit?
    private var isInitialized = false

    private init() {}

    // MARK: - Initialization

    private static func storageDirectory() -> URL {
        OsaurusPaths.workflows().appendingPathComponent("vectura", isDirectory: true)
    }

    /// Vector-only scoring (`hybridWeight: 1.0`) — deliberately NOT hybrid.
    ///
    /// BM25's Robertson IDF (`log((N-df+0.5)/(df+0.5))`) is negative for any
    /// term present in most of a tiny corpus: at N=1 every matching term
    /// scores below zero, which the hybrid combiner clamps to 0, capping the
    /// hybrid score at `cosine/2`. The workflows corpus *starts* at N=1 for
    /// every user, so cold start is exactly where the lane was structurally
    /// dead: a live 2026-06-10 session with one saved workflow scored 0.223
    /// for "osaurus workflow family office report" against the 0.25 lane
    /// floor and `capabilities_discover` returned nothing. The same doc in a
    /// 6-doc corpus scores 0.442. Pure cosine is corpus-size invariant
    /// (that query scores 0.446 at any N) and matches what the
    /// `CapabilitySearch.minimumRelevanceScoreWorkflows` floor was calibrated
    /// to mean ("embed-cosine acceptance floor"). Internal (not private) so
    /// the cold-start regression test exercises the production config.
    static func makeVecturaConfig(directoryURL: URL) throws -> VecturaConfig {
        try VecturaConfig(
            name: "osaurus-workflows",
            directoryURL: directoryURL,
            dimension: EmbeddingService.embeddingDimension,
            searchOptions: VecturaConfig.SearchOptions(
                defaultNumResults: 10,
                minThreshold: 0.3,
                hybridWeight: 1.0,
                k1: 1.2,
                b: 0.75
            ),
            memoryStrategy: .automatic()
        )
    }

    public func initialize() async {
        guard !isInitialized else { return }

        let storageDir = Self.storageDirectory()

        for attempt in 1 ... 2 {
            do {
                OsaurusPaths.ensureExistsSilent(storageDir)

                let config = try Self.makeVecturaConfig(directoryURL: storageDir)

                vectorDB = try await VecturaKit(config: config, embedder: EmbeddingService.sharedEmbedder)
                isInitialized = true
                rehydrateReverseIdMap()
                await reconcileIndexIfNeeded()
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

    // MARK: - Index reconciliation

    /// Marker recording which `indexSchemaVersion` built the on-disk
    /// index. Lives inside the vectura storage dir (but outside the
    /// per-collection document folder, so VecturaKit never tries to
    /// decode it) — the init-failure recovery path that deletes the
    /// storage dir therefore also resets the marker, forcing a rebuild.
    private struct IndexMeta: Codable {
        var schemaVersion: Int
    }

    private static func indexMetaURL() -> URL {
        storageDirectory().appendingPathComponent("index-meta.json")
    }

    /// The vector index is incrementally maintained (`indexWorkflow` /
    /// `removeWorkflow`) with no other sync point, so any missed write —
    /// a save while the service wasn't initialized, a wiped storage dir,
    /// a crash between DB insert and index add — silently makes that
    /// workflow undiscoverable forever. Reconcile at startup: rebuild
    /// when the schema version changed or the indexed set no longer
    /// matches the database.
    private func reconcileIndexIfNeeded() async {
        guard let db = vectorDB else { return }
        // The database is the source of truth; without it we can't tell
        // a stale index from a missing one — don't wipe anything.
        guard WorkflowDatabase.shared.isOpen,
            let workflows = try? WorkflowDatabase.shared.loadAllWorkflows()
        else { return }

        let meta = try? JSONDecoder().decode(IndexMeta.self, from: Data(contentsOf: Self.indexMetaURL()))
        var reason: String?
        if meta?.schemaVersion != Self.indexSchemaVersion {
            reason = "schema version \(meta?.schemaVersion.description ?? "none") != \(Self.indexSchemaVersion)"
        } else if let count = try? await db.documentCount, count != workflows.count {
            reason = "indexed count \(count) != database count \(workflows.count)"
        } else {
            for workflow in workflows {
                let exists = (try? await db.documentExists(id: deterministicUUID(for: workflow.id))) ?? false
                if !exists {
                    reason = "workflow \(workflow.id) missing from index"
                    break
                }
            }
        }

        guard let reason else { return }
        WorkflowLogger.search.notice("Workflow index out of sync (\(reason, privacy: .public)) — rebuilding")
        await rebuildIndex()
    }

    private func writeIndexMeta() {
        let meta = IndexMeta(schemaVersion: Self.indexSchemaVersion)
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: Self.indexMetaURL(), options: .atomic)
        }
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
            writeIndexMeta()
            WorkflowLogger.search.info("Workflow index rebuilt with \(workflows.count) workflows")
        } catch {
            WorkflowLogger.search.error("Failed to rebuild workflow index: \(error)")
        }
    }

    // MARK: - Helpers

    private var reverseIdMap: [String: String] = [:]

    private func buildIndexText(for workflow: Workflow, toolDescriptions: [String: String] = [:]) -> String {
        // The name leads the index text: models phrase discover queries with
        // the same tokens they used when naming the workflow (live miss:
        // `family_office_onepager` scored 0.227 vs the 0.25 floor with the
        // name absent). Underscores become spaces so the embedder sees the
        // same tokens BM25's punctuation-splitting tokenizer produces.
        var text = workflow.name.replacingOccurrences(of: "_", with: " ")
        text += " " + workflow.description
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
