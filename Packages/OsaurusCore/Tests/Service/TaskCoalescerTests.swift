//
//  TaskCoalescerTests.swift
//  osaurusTests
//
//  Direct coverage for the single-flight cache used by
//  `MLXBatchAdapter.Registry`. Verifies the construction-order
//  invariant (concurrent first-fetches share a single creator) and
//  the teardown discipline (in-flight creations are drained on
//  remove, not leaked).
//
//  Tests use a deliberately delayed factory so multiple concurrent
//  callers reliably observe the same in-flight `Task`. The factory's
//  invocation count and the value identity are the assertions.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("TaskCoalescer single-flight discipline")
struct TaskCoalescerTests {

    /// Sentinel value type. A mutable counter on a class lets the test
    /// observe both the number of factory invocations and the identity
    /// of each produced value (every factory run creates a new
    /// instance, so reference equality across coalesced callers is the
    /// cleanest signal that they share a single creation).
    final class Sentinel: @unchecked Sendable {
        let id: Int
        init(_ id: Int) { self.id = id }
    }

    /// Each creation increments `creates` so the test can assert the
    /// factory ran exactly once across N coalesced callers. Sleep is
    /// intentional: it widens the actor-suspension window so the
    /// harness reliably exercises the coalescing path even on a single
    /// CPU.
    actor SlowFactory {
        var creates = 0
        let sleepNanoseconds: UInt64
        init(sleepMs: UInt64 = 100) {
            self.sleepNanoseconds = sleepMs * 1_000_000
        }
        func make() async -> Sentinel {
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
            creates += 1
            return Sentinel(creates)
        }
    }

    @Test("Concurrent first-fetches for the same key produce one creation")
    func concurrentFirstFetches_coalesce() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory()
        async let a = coalescer.value(for: "k") { await factory.make() }
        async let b = coalescer.value(for: "k") { await factory.make() }
        async let c = coalescer.value(for: "k") { await factory.make() }
        async let d = coalescer.value(for: "k") { await factory.make() }
        async let e = coalescer.value(for: "k") { await factory.make() }
        let (va, vb, vc, vd, ve) = await (a, b, c, d, e)
        let creates = await factory.creates
        #expect(
            creates == 1,
            "factory ran \(creates) times; coalescer must invoke at most once for concurrent first-fetches"
        )
        #expect(va === vb && vb === vc && vc === vd && vd === ve)
    }

    @Test("Different keys do not coalesce with each other")
    func differentKeys_doNotCoalesce() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory()
        async let a = coalescer.value(for: "k1") { await factory.make() }
        async let b = coalescer.value(for: "k2") { await factory.make() }
        async let c = coalescer.value(for: "k3") { await factory.make() }
        let (va, vb, vc) = await (a, b, c)
        let creates = await factory.creates
        #expect(creates == 3, "expected 3 distinct creates, got \(creates)")
        #expect(va !== vb && vb !== vc && va !== vc)
    }

    @Test("Subsequent calls after first creation hit the cache, no re-create")
    func cacheHitPath() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory(sleepMs: 10)
        let v1 = await coalescer.value(for: "k") { await factory.make() }
        let v2 = await coalescer.value(for: "k") { await factory.make() }
        let v3 = await coalescer.value(for: "k") { await factory.make() }
        let creates = await factory.creates
        #expect(creates == 1)
        #expect(v1 === v2 && v2 === v3)
    }

    @Test("remove() drains an in-flight creation and returns the resolved value")
    func remove_drainsInFlight() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory(sleepMs: 80)
        // Kick off the creation.
        async let creating = coalescer.value(for: "k") { await factory.make() }
        // Wait long enough for the actor to park the task in `creating`,
        // but not so long that the factory finishes and writes `values`.
        try? await Task.sleep(nanoseconds: 10_000_000)
        // Race the in-flight creation. The remove call must await the
        // task and return the resolved value rather than nil.
        async let removed = coalescer.remove("k")
        let (creatingValue, removedValue) = await (creating, removed)
        #expect(removedValue != nil, "remove() lost the in-flight creation")
        #expect(removedValue === creatingValue)
        let creates = await factory.creates
        #expect(creates == 1)
        let snap = await coalescer.snapshot()
        #expect(snap.resolved == 0 && snap.inFlight == 0)
    }

    @Test("remove() returns nil for an unknown key")
    func remove_returnsNilForUnknownKey() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let removed = await coalescer.remove("never-stored")
        #expect(removed == nil)
    }

    @Test("remove() pulls a resolved entry and clears it")
    func remove_clearsResolved() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory(sleepMs: 5)
        let stored = await coalescer.value(for: "k") { await factory.make() }
        let removed = await coalescer.remove("k")
        #expect(removed === stored)
        let snap = await coalescer.snapshot()
        #expect(snap.resolved == 0 && snap.inFlight == 0)
        // Subsequent lookups must trigger a fresh creation.
        let freshFactory = SlowFactory(sleepMs: 5)
        let next = await coalescer.value(for: "k") { await freshFactory.make() }
        let freshCreates = await freshFactory.creates
        #expect(freshCreates == 1)
        #expect(next !== stored)
    }

    @Test("removeAll() drains in-flight + resolved together")
    func removeAll_drainsBoth() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let resolvedFactory = SlowFactory(sleepMs: 5)
        let inFlightFactory = SlowFactory(sleepMs: 80)
        // Resolve one entry to populate `values`.
        let resolved = await coalescer.value(for: "resolved") {
            await resolvedFactory.make()
        }
        // Kick off an in-flight creation that won't finish before we
        // call removeAll().
        async let pending = coalescer.value(for: "in-flight") {
            await inFlightFactory.make()
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let drained = await coalescer.removeAll()
        let pendingValue = await pending
        #expect(drained.count == 2)
        let byKey = Dictionary(uniqueKeysWithValues: drained.map { ($0.key, $0.value) })
        #expect(byKey["resolved"] === resolved)
        #expect(byKey["in-flight"] === pendingValue)
        let snap = await coalescer.snapshot()
        #expect(snap.resolved == 0 && snap.inFlight == 0)
    }
}
