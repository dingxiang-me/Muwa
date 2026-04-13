# Change Audit Log — memory-tools-defaults

> Running log of changes made on the `feat/memory-tools-defaults` branch.
> Each entry has: change ID, file, before/after, why, blast radius, audit focus.
>
> **Format**: Appended as changes land. Change IDs are `M-01` through `M-14`
> per the phase plan in `03-FIX-PLAN.md`.

---

## Format key

- **Change ID**: `M-NN` per the fix plan
- **Phase**: A / B / C / D / E
- **File**: Path relative to repo root
- **Kind**: `add` / `edit` / `remove`
- **Severity**: P0 / P1 / P2
- **Depends on**: Previous change IDs this builds on
- **Audit focus**: What reviewers should verify

---

## Entries

<!-- Changes will be appended below this line as work lands. -->

---

### M-01 — Fix `resolveTools` hard short-circuit

- **Phase**: A
- **File**: `Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift`
- **Kind**: `edit` — rewrite the early guard into a mode-aware check
- **Severity**: P1
- **Depends on**: None
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 4
- **Why**: Before this change, `guard !toolsDisabled else { return [] }` at
  line 168 stripped all tools — including per-agent explicit manual tools —
  the moment the global `disableTools` flag was `true`. After we flip the
  default in Phase D, every agent that was set up with
  `toolSelectionMode: .manual` + `manualToolNames: [...]` would silently
  lose its tool list. This fix makes the global flag mean "no auto-discovery
  and no built-in capability tools" rather than "no tools ever", so agents
  with explicit manual configuration keep working.

**Before** (lines 160-194):

```swift
/// Resolve the full tool set for a request: built-in + preflight/manual, deduped.
@MainActor
static func resolveTools(
    agentId: UUID,
    executionMode: WorkExecutionMode,
    toolsDisabled: Bool = false,
    preflight: PreflightResult = .empty
) -> [Tool] {
    guard !toolsDisabled else { return [] }

    let toolMode = AgentManager.shared.effectiveToolSelectionMode(for: agentId)
    let isManual = toolMode == .manual

    var tools = ToolRegistry.shared.alwaysLoadedSpecs(
        mode: executionMode,
        excludeCapabilityTools: isManual
    )
    var seen = Set(tools.map { $0.function.name })

    if isManual {
        if let manualNames = AgentManager.shared.effectiveManualToolNames(for: agentId) {
            for spec in ToolRegistry.shared.specs(forTools: manualNames)
            where seen.insert(spec.function.name).inserted {
                tools.append(spec)
            }
        }
    } else {
        for spec in preflight.toolSpecs
        where seen.insert(spec.function.name).inserted {
            tools.append(spec)
        }
    }

    return tools
}
```

**After**:

```swift
/// Resolve the full tool set for a request: built-in + preflight/manual, deduped.
///
/// Semantics of `toolsDisabled`:
/// - `false` (default) — normal path: always-loaded built-in tools +
///   preflight-selected auto tools or per-agent manual tools
/// - `true` — auto-discovery and built-in capability tools are blocked,
///   but per-agent **explicit manual tools** still run. This means an
///   agent that was configured with `toolSelectionMode: .manual` and
///   an explicit `manualToolNames` list keeps working even when the
///   global tools toggle is off. Use-case: user wants "no tools by
///   default" but has a handful of agents that need specific tools.
@MainActor
static func resolveTools(
    agentId: UUID,
    executionMode: WorkExecutionMode,
    toolsDisabled: Bool = false,
    preflight: PreflightResult = .empty
) -> [Tool] {
    let toolMode = AgentManager.shared.effectiveToolSelectionMode(for: agentId)
    let isManual = toolMode == .manual

    // When global tools are disabled and the agent isn't in manual mode,
    // return empty. Auto-discovery and preflight are blocked.
    if toolsDisabled && !isManual {
        return []
    }

    // Always-loaded built-in tools (capability search etc.) are only
    // injected when the global toggle is on. Manual-mode agents running
    // under a global disable skip them too — the user explicitly
    // configured their specific tool list.
    var tools: [Tool] = []
    if !toolsDisabled {
        tools = ToolRegistry.shared.alwaysLoadedSpecs(
            mode: executionMode,
            excludeCapabilityTools: isManual
        )
    }
    var seen = Set(tools.map { $0.function.name })

    if isManual {
        if let manualNames = AgentManager.shared.effectiveManualToolNames(for: agentId) {
            for spec in ToolRegistry.shared.specs(forTools: manualNames)
            where seen.insert(spec.function.name).inserted {
                tools.append(spec)
            }
        }
    } else {
        for spec in preflight.toolSpecs
        where seen.insert(spec.function.name).inserted {
            tools.append(spec)
        }
    }

    return tools
}
```

**Semantics diff**:

| State | Before | After |
|-------|--------|-------|
| `disableTools=false`, agent `.auto` | built-in + preflight tools | **unchanged** |
| `disableTools=false`, agent `.manual` | built-in (no capability) + manualToolNames | **unchanged** |
| `disableTools=true`, agent `.auto` | `[]` | `[]` (same) |
| `disableTools=true`, agent `.manual` | `[]` **(bug)** | `manualToolNames` only (fixed) |

The only behavior change is in the fourth row. Agents with explicit manual
tools now get them even under a global disable. This is the intended fix.

**Blast radius**:
- Every call site of `resolveTools` is unchanged — the function signature
  is identical. Only the internal behavior differs.
- Only one caller in the codebase: `SystemPromptComposer.finalizeContext`
  at line 132. The call there already passes `toolsDisabled: toolsDisabled`
  from the outer `composeChatContext` invocation. No plumbing changes needed.
- On main today, `disableTools` defaults to `false` so the new code path
  never fires. This change is a no-op until Phase D flips the default.
- After Phase D, agents with `.manual` mode get tools as intended. Agents
  with `.auto` mode still get nothing (matches the user's "no tools by default"
  direction).

**Audit focus**:
- Verify the comment docstring correctly describes the new semantics
- Verify the `if toolsDisabled && !isManual` guard matches the intent
  ("only return empty when global is off AND the agent isn't manual")
- Verify `isManual` is computed before the early return so the check works
- Verify the `alwaysLoadedSpecs` call is skipped under the global disable
  even for manual agents (user wants ONLY their manual list, not capability
  search tools that the user never explicitly selected)
- Grep for other call sites of `resolveTools` — should be zero outside this
  file. (`composeWorkPrompt` has its own separate tool resolution path that
  lives below `resolveTools` in the same file.)
- Run `swift test` to verify existing tests still pass. None of them exercise
  the `toolsDisabled=true && isManual=true` path specifically (since that path
  was broken before), so nothing should regress.

**Follow-up**: A dedicated unit test for the four-state matrix above would
be valuable. Deferred to Phase E tests (M-20).

---

### M-02 — Add `ChatWindowManager.allActiveSessionIds()` accessor

- **Phase**: A
- **File**: `Packages/OsaurusCore/Managers/Chat/ChatWindowManager.swift`
- **Kind**: `add` — new public method
- **Severity**: P1
- **Depends on**: None
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 8
- **Why**: Phase D needs to bulk-invalidate the preflight cache for every
  active session when `disableTools` changes in Settings. There's currently
  no way to enumerate session IDs from the manager — `closeWindow()` knows
  about a single session it's about to close, and that's it. Adding a
  dedicated accessor keeps the Settings save handler clean.

**New method** (inserted after `activeLocalModelNames()`, line ~274):

```swift
/// Returns every active chat session ID across all open windows.
///
/// Used by `ConfigurationView.saveConfiguration` to bulk-invalidate the
/// per-session preflight cache when `ChatConfiguration.disableTools`
/// changes — otherwise sessions keep serving stale tool specs from
/// before the toggle. See `docs/internal/memory-tools-defaults/02-VERIFIED-ISSUES.md`
/// Issue 8 for the reasoning.
///
/// Compacts out windows that don't have a session yet (fresh window,
/// model not selected, etc.) — those have nothing to invalidate.
public func allActiveSessionIds() -> [UUID] {
    windows.values.compactMap { $0.sessionId }
}
```

**Design choice**: reads from `windows` (the `[UUID: ChatWindowInfo]` dict at
line 36) rather than `windowStates`. `ChatWindowInfo.sessionId` is the
canonical record of what session a window belongs to; `windowStates` holds
the richer `ChatWindowState` object which may not be ready yet for freshly
opened windows. `windows` is the source of truth for "this window has a
session".

**Thread safety**: `ChatWindowManager` is `@MainActor` — all reads of
`windows` must happen on the main actor. Returning a `[UUID]` value type
makes the result safe to hand across async boundaries.

**Return semantics**:
- Returns all session IDs currently registered with the manager
- Includes work-mode windows (they also carry session IDs)
- Excludes windows that haven't been assigned a session (rare — usually
  just a brief window during creation)
- Returns an array, not a set — preserves window creation order, which
  doesn't matter for the invalidation use case but is cheaper than
  building a set

**Blast radius**:
- Purely additive. New method, no existing caller changes.
- Called in Phase D (M-17) by the Settings save handler.
- Also called in Phase C (M-11) by the chat-bar chip tap handler to
  invalidate its own session's preflight.

**Audit focus**:
- Verify `windows` is actually `[UUID: ChatWindowInfo]` with `sessionId`
  optional on `ChatWindowInfo` (confirmed at line 17 of the same file:
  `public let sessionId: UUID?`).
- Verify the method is `public` since `ConfigurationView` is in a sibling
  module subtree but the whole package is one module (`OsaurusCore`), so
  `internal` would also work. Using `public` for consistency with the rest
  of the class's API.
- Verify no existing method does the same thing under a different name.
  Grep for `sessionId` returns: `closeWindow` (single session), `windows`
  dict access in a few places. No existing enumerate-all helper.

---

### M-03 — Add batch + nuke preflight cache helpers to `PluginHostContext`

- **Phase**: A
- **File**: `Packages/OsaurusCore/Services/Plugin/PluginHostAPI.swift`
- **Kind**: `add` — two new static methods
- **Severity**: P1
- **Depends on**: None
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 8
- **Why**: The existing `invalidatePreflightCache(sessionId:)` at line 588
  takes a single session ID. Phase D needs to invalidate multiple sessions
  in one go when the user flips `disableTools` in Settings — iterating N
  times and acquiring the lock N times is wasteful and leaves a race
  window between invalidations. Adding a batch variant keeps the lock
  acquisition atomic.
  Also adding a nuke-everything variant for global plugin/tool registry
  changes, where enumerating every affected session is not possible.

**Existing method** (line 587-590, unchanged):

```swift
/// Call when a session ends (e.g. chat window closes) to release the memoized result.
static func invalidatePreflightCache(sessionId: String) {
    _ = preflightCacheLock.withLock { preflightCache.removeValue(forKey: sessionId) }
}
```

**New methods** (inserted after the existing one):

```swift
/// Bulk variant — invalidates the cached preflight result for every
/// session ID in `sessionIds`. Acquires the lock once and drops all
/// matching entries in a single critical section so Settings save can
/// flush cache for every open window without thrashing the lock.
///
/// Used by `ConfigurationView.saveConfiguration()` when
/// `ChatConfiguration.disableTools` changes — otherwise sessions with
/// cached tool specs from before the toggle keep injecting them into
/// the next request. See `docs/internal/memory-tools-defaults/02-VERIFIED-ISSUES.md`
/// Issue 8 for the reasoning.
static func invalidatePreflightCaches(sessionIds: [String]) {
    guard !sessionIds.isEmpty else { return }
    preflightCacheLock.withLock {
        for sid in sessionIds {
            preflightCache.removeValue(forKey: sid)
        }
    }
}

/// Drop every cached preflight result regardless of session. Used when
/// tool-affecting configuration changes globally (e.g., tool policies,
/// plugin install/uninstall) and we can't enumerate every affected
/// session ID cheaply.
static func invalidateAllPreflightCaches() {
    preflightCacheLock.withLock { preflightCache.removeAll() }
}
```

**Design choices**:

1. **Batch variant holds the lock once** for all N removals. Alternative
   was to call `invalidatePreflightCache(sessionId:)` N times, which would
   acquire + release the lock N times. For the expected use case (a handful
   of open windows), both work; the batch version is cleaner and avoids
   a theoretical race where a session is invalidated, immediately
   re-populated by a concurrent preflight, then the next iteration misses
   it. Not likely in practice, but correctness first.

2. **`guard !sessionIds.isEmpty else { return }`** on the batch variant
   avoids acquiring the lock at all when there's nothing to do. Cheap
   optimization; more importantly it makes the empty-case semantics
   obvious to readers.

3. **Nuke variant (`invalidateAllPreflightCaches`)** is speculative — not
   called by any code in this branch. Included because it's a trivial
   companion and future plugin install/uninstall flows will want it.
   Alternatively we could defer this until it has a caller. Kept it in
   for completeness since it's two lines.

**Blast radius**:
- Purely additive. Existing `invalidatePreflightCache(sessionId:)` is
  unchanged, so existing callers (`ChatWindowManager.closeWindow` at line
  580 of `ChatWindowManager.swift`) keep working.
- New methods are only called in later phases (C, D).

**Audit focus**:
- Verify the lock type: `preflightCacheLock` is `NSLock()` on line 585.
  `withLock { ... }` acquires + releases around the closure — correct.
- Verify the `preflightCache` type: `[String: PreflightResult]` at line 584.
  `removeValue(forKey:)` and `removeAll()` are standard Dictionary API.
- Verify no thread-safety issue with the `guard !sessionIds.isEmpty` check
  happening outside the lock — the argument is a value type `[String]`,
  captured by the guard, so no race.
- Confirm the nuke variant is safe to call: only touches
  `preflightCache`, no related caches are affected. (Scanning `PluginHostAPI.swift`
  for other caches: none related to preflight — `contexts` is plugin
  instance registry, `agentMappings` is plugin config, etc.)

---


