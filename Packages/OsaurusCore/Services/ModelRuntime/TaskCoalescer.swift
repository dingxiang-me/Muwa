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
/// Construction-order invariant inside `value(for:factory:)`:
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
/// Removal discipline (the `remove(_:)` / `removeAll()` direction):
///
/// `remove(_:)` and `removeAll()` must atomically (a) take exclusive
/// ownership of the in-flight `Task` so concurrent removers cannot
/// double-drain the same value (which would cause the caller to
/// double-shutdown the underlying resource), AND (b) keep the task
/// observable to concurrent `value(for:)` callers so they can join the
/// drain instead of starting a duplicate factory while the actor is
/// suspended on `await creation.value`.
///
/// The two requirements are met by moving the task from `creating[key]`
/// (which `value(for:)`'s start-new-task path keys off) into
/// `draining[key]` (which `value(for:)`'s join path also keys off).
/// First remover wins the move; the second remover finds `creating[key]`
/// nil and falls through to `values.removeValue(forKey:)`, which is
/// also nil during the drain — so the second remover gets `nil`.
///
/// **Removal-race invariant**: between the post-await resume of
/// `value(for:)` and its `values[key] = …` write, a concurrent
/// `remove(_:)` / `removeAll()` may have transferred the task to
/// `draining`. The canonicality check (`creating[key] == ourTask`)
/// then fails (since the slot is empty), so `value(for:)` does not
/// commit a stale entry the user just asked to remove.
public actor TaskCoalescer<Value: Sendable> {
    private var values: [String: Value] = [:]
    private var creating: [String: Task<Value, Never>] = [:]
    private var draining: [String: Task<Value, Never>] = [:]

    public init() {}

    /// Resolve the value for `key`, creating it via `factory` on first
    /// access. Concurrent callers for the same `key` share a single
    /// `factory` invocation and observe the same returned `Value`.
    ///
    /// Lookup order:
    ///   1. `values[key]`   — resolved cache hit.
    ///   2. `creating[key]` — in-flight first-fetch; join it.
    ///   3. `draining[key]` — in-flight teardown; join it. Crucially,
    ///      callers landing here do NOT start a fresh factory: the
    ///      `Task` is on its way out, but starting a duplicate would
    ///      put two consumers on the underlying resource (e.g. two
    ///      `BatchEngine`s on the same `ModelContainer`).
    ///   4. otherwise — start a new factory.
    public func value(
        for key: String,
        factory: @Sendable @escaping () async -> Value
    ) async -> Value {
        if let existing = values[key] { return existing }
        if let inFlight = creating[key] {
            return await inFlight.value
        }
        if let drainingTask = draining[key] {
            // A concurrent `remove(_:)` / `removeAll()` owns this task.
            // We observe the same resolved value but do not take
            // ownership; not starting a duplicate factory is the
            // load-bearing invariant for callers like
            // `MLXBatchAdapter.Registry` whose underlying resource
            // (a `BatchEngine` on a shared `ModelContainer`) cannot
            // tolerate two simultaneous owners.
            return await drainingTask.value
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
    ///
    /// Concurrent removers: the first call removes `creating[key]`
    /// (atomic on the actor), tombstones it into `draining[key]`, and
    /// awaits. A second concurrent `remove(_:)` finds `creating[key]`
    /// nil and falls through to `values.removeValue(forKey:)`, which is
    /// also nil during the drain — so the second remover returns
    /// `nil`. Exclusive ownership transfer prevents double-shutdown.
    @discardableResult
    public func remove(_ key: String) async -> Value? {
        if let creation = creating.removeValue(forKey: key) {
            // Tombstone the task so concurrent `value(for:)` callers
            // can join (no duplicate factory). Cleared after our await
            // so a fresh `value(for:)` after the drain is allowed to
            // start a new task.
            draining[key] = creation
            let value = await creation.value
            // Canonicality: clear only if our task is still the
            // registered drainer (defensive; `draining` has a single
            // writer per key — the `remove(_:)`/`removeAll()` that
            // tombstoned the task — but the dict-eq check costs nothing
            // and locks against future drift).
            if draining[key] == creation {
                draining[key] = nil
            }
            // The original `value(for:)` starter that was awaiting
            // `creation.value` will see `creating[key] != ourTask`
            // (since we removed it above) and skip the commit, so
            // `values[key]` cannot have been written during our
            // drain — no sweep needed.
            return value
        }
        return values.removeValue(forKey: key)
    }

    /// Drain every entry — both already-resolved and in-flight — and
    /// return them all. Use the returned entries to release the
    /// underlying resources. Same removal-race discipline as
    /// `remove(_:)`: concurrent `value(for:)` callers join the
    /// `draining[key]` tombstone while we await.
    @discardableResult
    public func removeAll() async -> [(key: String, value: Value)] {
        let pending = creating
        creating.removeAll()
        // Move every in-flight task to `draining` BEFORE the first
        // await, so a `value(for:)` that lands in the gap between
        // iterations finds the task on the join path and never starts
        // a duplicate factory.
        for (key, task) in pending {
            draining[key] = task
        }
        // Snapshot resolved entries before the awaits — a concurrent
        // `value(for:)` that completes a fresh creation during our
        // drain (after its tombstone clears) writes to `values[key]`,
        // and that fresh entry is NOT one we asked to remove.
        let preExistingValues = values
        values.removeAll()

        var resolved: [(key: String, value: Value)] = []
        for (key, creation) in pending {
            let value = await creation.value
            resolved.append((key, value))
            draining[key] = nil
        }
        for (key, value) in preExistingValues {
            resolved.append((key, value))
        }
        return resolved
    }

    /// Diagnostic accessor: caller-side test instrument for asserting
    /// that the coalescer holds the expected number of resolved /
    /// in-flight / draining entries. Not used on the production path.
    public func snapshot() -> (resolved: Int, inFlight: Int, draining: Int) {
        (values.count, creating.count, draining.count)
    }
}
