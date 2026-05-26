# Family Runtime Matrix

This document tracks the post-merge runtime proof lane for local model families
whose tool parsing, reasoning templates, media paths, and cache topologies cannot
be proven by generic OpenAI-compatible request tests alone.

## Scope

The next production claim requires source gates plus live Osaurus chat/API proof
for each downloaded or locally available family:

| Family | Local evidence target | Cache topology that must be proven | Live proof status |
| --- | --- | --- | --- |
| Nemotron Omni | `Nemotron-Omni-Nano-*` local bundles | hybrid SSM companion state, prefix/L2 disk, media cache salt for audio/video rows | pending |
| Ling / Bailing | `Ling-2.6-flash-*` local bundles | hybrid linear-attention/SSM companion state, prefix/L2 disk | pending |
| ZAYA text | `ZAYA1-8B-*` local bundles | ZAYA CCA companion state, path-dependent restore, prefix/L2 disk | pending |
| ZAYA VL | `ZAYA1-VL-8B-*` local bundles | ZAYA CCA plus real image payload and media cache salt | pending |
| HY3 / Hunyuan | local `Hy3-preview` source or bundle | Hunyuan reasoning-effort template, Hunyuan tool parser, cache topology after load | local bundle pending |

## Non-Negotiables

- Do not force coherence with synthetic sampler defaults, hidden repetition
  penalties, forced thinking tags, forced reasoning closers, prompt coercion, or
  parser-side stripping that hides protocol bugs.
- Generation parameters must remain absent unless the user/API explicitly sends
  them. Model defaults come from the bundle/runtime configuration.
- Tool proof must use actual `tool_choice` and `tools` wiring through the local
  vMLX template/decode path, then verify structured tool calls and no visible
  protocol leakage.
- Multi-turn proof must include a tool result followed by a second model turn in
  the same chat/session. Load-only or one-shot output is not production proof.
- Cache proof must match the architecture. Hybrid SSM, ZAYA CCA, DSV4 hybrid
  pool, and media payloads need their companion-state evidence; generic KV/L2
  counters are not enough.
- TurboQuant KV remains opt-in until every relevant family/topology has a live
  row proving correctness under that mode.

## Required Row Shape

Each live row must record:

- Osaurus commit, vMLX pin, app path, app PID, model path, and request endpoint
  or UI steps.
- Request payload: model, messages, tools, `tool_choice`, reasoning controls,
  and explicit sampler fields if any.
- Visible content, reasoning deltas, tool calls, finish reason, and parser leak
  check.
- Token/s, load memory, generation memory, and Activity Monitor physical
  footprint when available.
- `/health` and `/admin/cache-stats` before/after with topology-specific
  counters: prefix/paged hits, disk L2 hits/stores, SSM/CCA companion hits or
  re-derives, media cache salt/hit where applicable, and TurboQuant counters
  only when explicitly enabled.

## Current Source Baseline

The merged runtime already contains:

- `tool_choice` propagation into local template context for required/named tool
  calls.
- Family matchers for Nemotron Omni, Ling, ZAYA, and ZAYA VL.
- HY3 reasoning-effort profile and Hunyuan parser aliases.
- `/admin/cache-stats` topology output for SSM, ZAYA CCA, hybrid pool, disk L2,
  and TurboQuant counters.

The source baseline is necessary but not sufficient. Live rows remain pending.
