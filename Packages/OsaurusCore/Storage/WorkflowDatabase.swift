//
//  WorkflowDatabase.swift
//  osaurus
//
//  SQLite database for the workflows subsystem.
//  WAL mode, serial queue, versioned migrations — follows MemoryDatabase patterns.
//

import Foundation
import OsaurusSQLCipher

// MARK: - Error

public enum WorkflowDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let msg): return "Failed to open workflow database: \(msg)"
        case .failedToExecute(let msg): return "Failed to execute query: \(msg)"
        case .failedToPrepare(let msg): return "Failed to prepare statement: \(msg)"
        case .migrationFailed(let msg): return "Workflow migration failed: \(msg)"
        case .notOpen: return "Workflow database is not open"
        }
    }
}

// MARK: - WorkflowDatabase

public final class WorkflowDatabase: @unchecked Sendable {
    public static let shared = WorkflowDatabase()

    private static let schemaVersion = 1

    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private static func iso8601Now() -> String {
        iso8601Formatter.string(from: Date())
    }

    static func dateFromISO8601(_ string: String) -> Date {
        iso8601Formatter.date(from: string) ?? Date()
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.workflows.database")
    private let stmtCache = PreparedStatementCache(capacity: 32)

    public var isOpen: Bool {
        queue.sync { db != nil }
    }

    init() {}

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        // See `ChatHistoryDatabase.open()` for the gate rationale.
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.workflows())
            try openConnection()
            try runMigrations()
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "workflows",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in try? self?.open() }
    )

    func openInMemory() throws {
        try queue.sync {
            guard db == nil else { return }
            db = try EncryptedSQLiteOpener.open(
                path: ":memory:",
                key: nil,
                applyPerfPragmas: false
            )
            try runMigrations()
        }
    }

    public func close() {
        OsaurusDatabaseHandle.deregister(name: "workflows")
        queue.sync {
            stmtCache.clear()
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
        }
    }

    // MARK: - Connection

    private func openConnection() throws {
        let path = OsaurusPaths.workflowsDatabaseFile().path
        let key = try StorageKeyManager.shared.currentKey()
        do {
            db = try EncryptedSQLiteOpener.open(path: path, key: key)
        } catch let error as EncryptedSQLiteError {
            throw WorkflowDatabaseError.failedToOpen(error.localizedDescription)
        }
    }

    // MARK: - Schema & Migrations

    private func runMigrations() throws {
        let currentVersion = try getSchemaVersion()
        if currentVersion < 1 {
            try createSchema()
        }
    }

    private func getSchemaVersion() throws -> Int {
        var version: Int = 0
        try executeRaw("PRAGMA user_version") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = Int(sqlite3_column_int(stmt, 0))
            }
        }
        return version
    }

    private func setSchemaVersion(_ version: Int) throws {
        try executeRaw("PRAGMA user_version = \(version)")
    }

    private func createSchema() throws {
        WorkflowLogger.database.info("Creating workflow schema")

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS workflows (
                    id              TEXT PRIMARY KEY,
                    name            TEXT NOT NULL,
                    description     TEXT NOT NULL,
                    trigger_text    TEXT,
                    body            TEXT NOT NULL,
                    source          TEXT NOT NULL,
                    source_model    TEXT,
                    tier            TEXT NOT NULL DEFAULT 'active',
                    parameters      TEXT,
                    steps           TEXT,
                    tools_used      TEXT,
                    skills_used     TEXT,
                    token_count     INTEGER NOT NULL,
                    version         INTEGER NOT NULL DEFAULT 1,
                    created_at      TEXT NOT NULL,
                    updated_at      TEXT NOT NULL
                )
            """
        )

        try executeRaw("CREATE INDEX IF NOT EXISTS idx_workflows_tier ON workflows(tier)")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_workflows_name ON workflows(name)")

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS workflow_events (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    workflow_id     TEXT NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
                    event_type      TEXT NOT NULL,
                    model_used      TEXT,
                    agent_id        TEXT,
                    notes           TEXT,
                    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )

        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_workflow_events_workflow ON workflow_events(workflow_id, event_type)"
        )
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_workflow_events_created ON workflow_events(created_at)")

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS workflow_scores (
                    workflow_id     TEXT PRIMARY KEY REFERENCES workflows(id) ON DELETE CASCADE,
                    times_loaded    INTEGER NOT NULL DEFAULT 0,
                    times_succeeded INTEGER NOT NULL DEFAULT 0,
                    times_failed    INTEGER NOT NULL DEFAULT 0,
                    success_rate    REAL NOT NULL DEFAULT 0.0,
                    last_used_at    TEXT,
                    score           REAL NOT NULL DEFAULT 0.0
                )
            """
        )

        try setSchemaVersion(Self.schemaVersion)
        WorkflowLogger.database.info("Workflow schema created")
    }

    // MARK: - Raw Execution

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else {
            throw WorkflowDatabaseError.notOpen
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw WorkflowDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else {
            throw WorkflowDatabaseError.notOpen
        }
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let statement = stmt else {
            let message = String(cString: sqlite3_errmsg(connection))
            throw WorkflowDatabaseError.failedToPrepare(message)
        }
        defer { sqlite3_finalize(statement) }
        try handler(statement)
    }

    private func prepareAndExecute(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        try queue.sync {
            guard let connection = db else {
                throw WorkflowDatabaseError.notOpen
            }
            var stmt: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
            guard prepareResult == SQLITE_OK, let statement = stmt else {
                let message = String(cString: sqlite3_errmsg(connection))
                throw WorkflowDatabaseError.failedToPrepare(message)
            }
            defer { sqlite3_finalize(statement) }
            bind(statement)
            try process(statement)
        }
    }

    private func executeUpdate(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        try prepareAndExecute(sql, bind: bind) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw WorkflowDatabaseError.failedToExecute("step failed")
            }
        }
    }

    // MARK: - Workflows CRUD

    private static let workflowColumns = """
        id, name, description, trigger_text, body, source, source_model,
        tier, parameters, steps, tools_used, skills_used, token_count, version, created_at, updated_at
        """

    public func insertWorkflow(_ workflow: Workflow) throws {
        let now = Self.iso8601Now()
        try executeUpdate(
            """
            INSERT INTO workflows (\(Self.workflowColumns))
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: workflow.id)
            Self.bindText(stmt, index: 2, value: workflow.name)
            Self.bindText(stmt, index: 3, value: workflow.description)
            Self.bindText(stmt, index: 4, value: workflow.triggerText)
            Self.bindText(stmt, index: 5, value: workflow.body)
            Self.bindText(stmt, index: 6, value: workflow.source.rawValue)
            Self.bindText(stmt, index: 7, value: workflow.sourceModel)
            Self.bindText(stmt, index: 8, value: workflow.tier.rawValue)
            Self.bindText(stmt, index: 9, value: Self.encodeJSON(workflow.parameters))
            Self.bindText(stmt, index: 10, value: Self.encodeJSON(workflow.steps))
            Self.bindText(stmt, index: 11, value: Self.encodeJSON(workflow.toolsUsed))
            Self.bindText(stmt, index: 12, value: Self.encodeJSON(workflow.skillsUsed))
            sqlite3_bind_int(stmt, 13, Int32(workflow.tokenCount))
            sqlite3_bind_int(stmt, 14, Int32(workflow.version))
            Self.bindText(stmt, index: 15, value: now)
            Self.bindText(stmt, index: 16, value: now)
        }

        try upsertScore(WorkflowScore(workflowId: workflow.id))
    }

    public func updateWorkflow(_ workflow: Workflow) throws {
        let now = Self.iso8601Now()
        try executeUpdate(
            """
            UPDATE workflows SET name = ?1, description = ?2, trigger_text = ?3, body = ?4,
                source = ?5, source_model = ?6, tier = ?7, parameters = ?8, steps = ?9,
                tools_used = ?10, skills_used = ?11, token_count = ?12, version = ?13, updated_at = ?14
            WHERE id = ?15
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: workflow.name)
            Self.bindText(stmt, index: 2, value: workflow.description)
            Self.bindText(stmt, index: 3, value: workflow.triggerText)
            Self.bindText(stmt, index: 4, value: workflow.body)
            Self.bindText(stmt, index: 5, value: workflow.source.rawValue)
            Self.bindText(stmt, index: 6, value: workflow.sourceModel)
            Self.bindText(stmt, index: 7, value: workflow.tier.rawValue)
            Self.bindText(stmt, index: 8, value: Self.encodeJSON(workflow.parameters))
            Self.bindText(stmt, index: 9, value: Self.encodeJSON(workflow.steps))
            Self.bindText(stmt, index: 10, value: Self.encodeJSON(workflow.toolsUsed))
            Self.bindText(stmt, index: 11, value: Self.encodeJSON(workflow.skillsUsed))
            sqlite3_bind_int(stmt, 12, Int32(workflow.tokenCount))
            sqlite3_bind_int(stmt, 13, Int32(workflow.version))
            Self.bindText(stmt, index: 14, value: now)
            Self.bindText(stmt, index: 15, value: workflow.id)
        }
    }

    public func loadWorkflow(id: String) throws -> Workflow? {
        var workflow: Workflow?
        try prepareAndExecute(
            "SELECT \(Self.workflowColumns) FROM workflows WHERE id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: id) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    workflow = Self.readWorkflow(from: stmt)
                }
            }
        )
        return workflow
    }

    public func loadAllWorkflows() throws -> [Workflow] {
        var workflows: [Workflow] = []
        try prepareAndExecute(
            "SELECT \(Self.workflowColumns) FROM workflows ORDER BY updated_at DESC",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    workflows.append(Self.readWorkflow(from: stmt))
                }
            }
        )
        return workflows
    }

    public func loadWorkflowsByIds(_ ids: [String]) throws -> [Workflow] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
        var workflows: [Workflow] = []
        try prepareAndExecute(
            "SELECT \(Self.workflowColumns) FROM workflows WHERE id IN (\(placeholders))",
            bind: { stmt in
                for (i, id) in ids.enumerated() {
                    Self.bindText(stmt, index: Int32(i + 1), value: id)
                }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    workflows.append(Self.readWorkflow(from: stmt))
                }
            }
        )
        return workflows
    }

    public func deleteWorkflow(id: String) throws {
        try executeUpdate("DELETE FROM workflows WHERE id = ?1") { stmt in
            Self.bindText(stmt, index: 1, value: id)
        }
    }

    // MARK: - Workflow Events

    public func insertEvent(_ event: WorkflowEvent) throws {
        try executeUpdate(
            """
            INSERT INTO workflow_events (workflow_id, event_type, model_used, agent_id, notes, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: event.workflowId)
            Self.bindText(stmt, index: 2, value: event.eventType.rawValue)
            Self.bindText(stmt, index: 3, value: event.modelUsed)
            Self.bindText(stmt, index: 4, value: event.agentId)
            Self.bindText(stmt, index: 5, value: event.notes)
            Self.bindText(stmt, index: 6, value: Self.iso8601Formatter.string(from: event.createdAt))
        }
    }

    public func loadEvents(workflowId: String, ofType type: WorkflowEventType? = nil) throws -> [WorkflowEvent] {
        var events: [WorkflowEvent] = []
        let sql: String
        let bindFn: (OpaquePointer) -> Void

        if let type {
            sql =
                "SELECT id, workflow_id, event_type, model_used, agent_id, notes, created_at FROM workflow_events WHERE workflow_id = ?1 AND event_type = ?2 ORDER BY created_at"
            bindFn = { stmt in
                Self.bindText(stmt, index: 1, value: workflowId)
                Self.bindText(stmt, index: 2, value: type.rawValue)
            }
        } else {
            sql =
                "SELECT id, workflow_id, event_type, model_used, agent_id, notes, created_at FROM workflow_events WHERE workflow_id = ?1 ORDER BY created_at"
            bindFn = { stmt in
                Self.bindText(stmt, index: 1, value: workflowId)
            }
        }

        try prepareAndExecute(sql, bind: bindFn) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                events.append(Self.readEvent(from: stmt))
            }
        }
        return events
    }

    // MARK: - Workflow Scores

    public func loadScore(workflowId: String) throws -> WorkflowScore? {
        var score: WorkflowScore?
        try prepareAndExecute(
            """
            SELECT workflow_id, times_loaded, times_succeeded, times_failed,
                   success_rate, last_used_at, score
            FROM workflow_scores WHERE workflow_id = ?1
            """,
            bind: { stmt in Self.bindText(stmt, index: 1, value: workflowId) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    score = Self.readScore(from: stmt)
                }
            }
        )
        return score
    }

    public func upsertScore(_ score: WorkflowScore) throws {
        try executeUpdate(
            """
            INSERT INTO workflow_scores (workflow_id, times_loaded, times_succeeded, times_failed,
                                         success_rate, last_used_at, score)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(workflow_id) DO UPDATE SET
                times_loaded = excluded.times_loaded,
                times_succeeded = excluded.times_succeeded,
                times_failed = excluded.times_failed,
                success_rate = excluded.success_rate,
                last_used_at = excluded.last_used_at,
                score = excluded.score
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: score.workflowId)
            sqlite3_bind_int(stmt, 2, Int32(score.timesLoaded))
            sqlite3_bind_int(stmt, 3, Int32(score.timesSucceeded))
            sqlite3_bind_int(stmt, 4, Int32(score.timesFailed))
            sqlite3_bind_double(stmt, 5, score.successRate)
            if let last = score.lastUsedAt {
                Self.bindText(stmt, index: 6, value: Self.iso8601Formatter.string(from: last))
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_bind_double(stmt, 7, score.score)
        }
    }

    // MARK: - Row Readers

    private static func readWorkflow(from stmt: OpaquePointer) -> Workflow {
        Workflow(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            name: String(cString: sqlite3_column_text(stmt, 1)),
            description: String(cString: sqlite3_column_text(stmt, 2)),
            triggerText: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
            body: String(cString: sqlite3_column_text(stmt, 4)),
            source: WorkflowSource(rawValue: String(cString: sqlite3_column_text(stmt, 5))) ?? .user,
            sourceModel: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
            tier: WorkflowTier(rawValue: String(cString: sqlite3_column_text(stmt, 7))) ?? .active,
            parameters: decodeJSON(sqlite3_column_text(stmt, 8).map { String(cString: $0) }),
            steps: decodeJSON(sqlite3_column_text(stmt, 9).map { String(cString: $0) }),
            toolsUsed: decodeJSON(sqlite3_column_text(stmt, 10).map { String(cString: $0) }),
            skillsUsed: decodeJSON(sqlite3_column_text(stmt, 11).map { String(cString: $0) }),
            tokenCount: Int(sqlite3_column_int(stmt, 12)),
            version: Int(sqlite3_column_int(stmt, 13)),
            createdAt: dateFromISO8601(String(cString: sqlite3_column_text(stmt, 14))),
            updatedAt: dateFromISO8601(String(cString: sqlite3_column_text(stmt, 15)))
        )
    }

    private static func readEvent(from stmt: OpaquePointer) -> WorkflowEvent {
        WorkflowEvent(
            id: Int(sqlite3_column_int(stmt, 0)),
            workflowId: String(cString: sqlite3_column_text(stmt, 1)),
            eventType: WorkflowEventType(rawValue: String(cString: sqlite3_column_text(stmt, 2))) ?? .loaded,
            modelUsed: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
            agentId: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            notes: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
            createdAt: dateFromISO8601(String(cString: sqlite3_column_text(stmt, 6)))
        )
    }

    private static func readScore(from stmt: OpaquePointer) -> WorkflowScore {
        WorkflowScore(
            workflowId: String(cString: sqlite3_column_text(stmt, 0)),
            timesLoaded: Int(sqlite3_column_int(stmt, 1)),
            timesSucceeded: Int(sqlite3_column_int(stmt, 2)),
            timesFailed: Int(sqlite3_column_int(stmt, 3)),
            successRate: sqlite3_column_double(stmt, 4),
            lastUsedAt: sqlite3_column_text(stmt, 5).map { dateFromISO8601(String(cString: $0)) },
            score: sqlite3_column_double(stmt, 6)
        )
    }

    // MARK: - JSON Helpers

    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func decodeJSON<T: Decodable>(_ string: String?) -> [T] where T: Sendable {
        guard let string, let data = string.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }
}

// MARK: - SQLite Helpers

private let workflowSqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension WorkflowDatabase {
    static func bindText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, value, -1, workflowSqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
