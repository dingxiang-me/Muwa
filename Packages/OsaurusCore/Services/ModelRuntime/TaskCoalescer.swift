//
//  TaskCoalescer.swift
//  osaurus
//
//  Generic single-flight cache for async resource creation. Concurrent
//  callers requesting the same key all observe the same in-flight `Task`
//  and therefore the same returned value. Used by
//  `MLXBatchAdapter.Registry` to avoid building a duplicate `BatchEngine`
//  on the same MLX `ModelContainer`, which would put two consumers on the
//  shared GPU command queue and surface as Metal completion-queue
//  abort (`MTLReleaseAssertionFailure`).
//

import Foundation

/// Single-flight cache: at most one creator per key is in flight at a
/// time, every concurrent caller observes the same resolved value.
///
/// Construction order inside `value(for:factory:)` is significant:
///   1. Park the in-flight `Task` in `creating[key]` *before* awaiting it,
///      so any caller that lands while the actor is suspended in
///      `await task.value` finds the task and joins instead of starting
///      a second creation.
///   2. After the await, write `values[key] = value` *before* clearing
///      `creating[key]`. A caller that lands between these two writes
///      either observes the resolved value (cache hit) or the still-set
///      in-flight task (joins the same task) — never the empty state
///      that would trigger a second creation.
///
/// `remove(_:)` and `removeAll()` mirror that discipline for the
/// teardown direction: an in-flight creation is awaited to its resolved
/// value and that value is returned, so the caller can dispose of a
/// freshly-created resource (e.g. `shutdown()` a `BatchEngine`) without
/// leaking it.
public actor TaskCoalescer<Value: Sendable> {
    private var values: [String: Value] = [:]
    private var creating: [String: Task<Value, Never>] = [:]

    public init() {}

    /// Resolve the value for `key`, creating it via `factory` on first
    /// access. Concurrent callers for the same `key` share a single
    /// `factory` invocation and observe the same returned `Value`.
    ///
    /// **Removal-race invariant**: between the post-await resume of
    /// this method and its `values[key] = …` write, a concurrent
    /// `remove(_:)` / `removeAll()` may yank the in-flight task. The
    /// canonicality check (`creating[key] === ourTask`) ensures we
    /// only commit when the task we started is still the registered
    /// owner; if it was already removed, we return the resolved
    /// value but leave both maps untouched. The other caller already
    /// took ownership.
    public func value(
        for key: String,
        factory: @Sendable @escaping () async -> Value
    ) async -> Value {
        if let existing = values[key] { return existing }
        if let inFlight = creating[key] {
            return await inFlight.value
        }
        let ourTask = Task<Value, Never> { await factory() }
        creating[key] = ourTask
        let value = await ourTask.value
        if creating[key] == ourTask {
            values[key] = value
            creating[key] = nil
        }
        return value
    }

    /// Remove and return the cached entry for `key`, draining any
    /// in-flight creation first. Callers use the returned value to
    /// release the resource it represents (e.g. `engine.shutdown()`).
    /// Returns `nil` when no entry exists.
    @discardableResult
    public func remove(_ key: String) async -> Value? {
        if let creation = creating.removeValue(forKey: key) {
            // The concurrent `value(for:)` invocation that owns this
            // task will see `creating[key] != ourTask` after its await
            // resumes and skip the `values[key] = …` write. We are the
            // exclusive holder of the resolved value once the task
            // finishes, so subsequent lookups via `values[key]` will
            // miss (correct: the entry has been removed).
            return await creation.value
        }
        return values.removeValue(forKey: key)
    }

    /// Drain every entry — both already-resolved and in-flight — and
    /// return them all. Use the returned entries to release the
    /// underlying resources. Same removal-race discipline as
    /// `remove(_:)`: in-flight `value(for:)` invocations whose task
    /// we yank here will observe the canonicality miss and decline to
    /// write to `values`.
    @discardableResult
    public func removeAll() async -> [(key: String, value: Value)] {
        let pending = creating
        creating.removeAll()
        var resolved: [(key: String, value: Value)] = []
        for (key, creation) in pending {
            resolved.append((key, await creation.value))
        }
        for (key, value) in values {
            resolved.append((key, value))
        }
        values.removeAll()
        return resolved
    }

    /// Diagnostic accessor: caller-side test instrument for asserting
    /// that the coalescer holds the expected number of resolved /
    /// in-flight entries. Not used on the production path.
    public func snapshot() -> (resolved: Int, inFlight: Int) {
        (values.count, creating.count)
    }
}
