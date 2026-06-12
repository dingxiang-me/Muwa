# Gemma Cache Defaults, Prefill Progress, and Harness PR

This is the active Osaurus integration checklist for the paired vMLX work.

## Scope

- Default paged RAM KV cache is off. Prefix reuse must still use disk/L2 cache
  by default so single-batch users do not pay for an extra RAM tier.
- Eligible Gemma 4 QAT MXFP4 and JANG_4M models use TurboQuant KV by default
  from Chat UI and server settings. Architecture-specific exceptions must be
  recorded as runtime topology, not hidden behind UI copy.
- vMLX emits `Generation.prefillProgress`; Osaurus maps it to
  `ModelRuntimeEvent.prefillProgress`, `\u{FFFE}prefill:` stream hints, and
  `InferenceProgressManager` so Chat UI shows prefill percentage/stage before
  first token.
- Gemma 4 QAT MXFP4 and JANG_4M rows must run through the harness contract in
  `docs/HARNESS_COMPATIBILITY.md`, with scores recorded and score blockers
  fixed, before this is called merge-ready.
- Do not load, benchmark, or count non-QAT/source-looking Gemma bundles for this
  checkpoint. The active scope is only the OsaurusAI Gemma 4 QAT MXFP4 and
  JANG_4M repos listed below.
- Regression note: errors such as
  `Unhandled keys ["down_proj", "gate_up_proj"] ... TextExperts` from
  source/unquantized Gemma expert weights are not part of this checkpoint. They
  should stay documented as out-of-scope source-bundle failures, not chased as
  blockers for the QAT MXFP4/JANG_4M rows.

## Local Model Inventory

Downloaded under `~/models`:

- `OsaurusAI--gemma-4-E2B-it-qat-MXFP4`
- `OsaurusAI--gemma-4-E4B-it-qat-MXFP4`
- `OsaurusAI--gemma-4-12B-it-qat-MXFP4`
- `OsaurusAI--gemma-4-26B-A4B-it-qat-MXFP4`
- `OsaurusAI--gemma-4-31B-it-qat-MXFP4`
- `OsaurusAI--gemma-4-E2B-it-qat-JANG_4M`
- `OsaurusAI--gemma-4-E4B-it-qat-JANG_4M`
- `OsaurusAI--gemma-4-12B-it-qat-JANG_4M`
- `OsaurusAI--gemma-4-26B-A4B-it-qat-JANG_4M`
- `OsaurusAI--gemma-4-31B-it-qat-JANG_4M`

Download log directory:
`/Users/eric/models/.download-logs/gemma4-qat-screen-20260611T222059Z`.

Other local Gemma directories can exist under `/Users/eric/models`, including
Google/source-looking test folders. They are explicitly out of scope here and
must not be used for load, tool, cache, or harness proof in this checkpoint.

## Checkpoint Proof Matrix

This is the active tracking matrix for the team-testable checkpoint. Do not
mark a row `PROVEN` unless the artifact paths exist and the row proves the
production Osaurus path, not just source inspection.

Required proof columns:

- `Inventory`: local bundle exists under `/Users/eric/models`, has config,
  tokenizer, processor when multimodal, and all expected safetensor shards.
- `Load/Chat`: unsigned/dev Osaurus app or server loads the model and returns
  coherent visible text with no loops, hidden-only output, raw parser markers,
  or forced-template behavior.
- `Prefix/L2`: two long-prefix prompts prove SSD/L2 prefix cache behavior with
  `cache.pagedKV.enabled=false`, `block_disk_store.enabled=true`,
  `disk_l2_hits > 0`, `disk_l2_stores > 0`, and `paged_hits=0`.
- `TQ/SWA`: cache stats prove `effective_kv_mode="turbo(...)"`,
  TurboQuant compression count when the row generates, and Gemma SWA/rotating
  layers stay disk-backed with `requires_disk_backed_restore=true`.
- `Speed`: every generation row records token/s and, where the API exposes it,
  TTFT or enough timestamp evidence to calculate TTFT. Missing token/s means
  the row is incomplete.
- `Tools`: direct OpenAI-compatible tool-call row proves exact tool name,
  exact JSON arguments, and a tool-result continuation with visible answer.
- `Agent`: Osaurus agent/tool loop route runs without Gemma chat-template
  failures and records tool/result behavior where the branch supports it.
- `VL`: real image payload through Osaurus works for rows whose config has
  `vision_config`.
- `Audio`: real audio payload through Osaurus works for rows whose config has
  `audio_config`.
- `Prefill UI/API`: slow/long prompt emits `osaurus_prefill` chunks and the
  Chat UI surfaces percent/stage before first token.
- `Memory`: RSS and, for final checkpoint, Activity Monitor physical footprint
  are recorded during load and generation on the dev app path.

Current model capability metadata from local `config.json`:

| Model | Format | Config family | Vision | Audio | Inventory | Load/Chat | Prefix/L2 | TQ/SWA | Speed | Tools | Agent | VL | Audio | Prefill UI/API | Memory |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `osaurusai--gemma-4-e2b-it-qat-mxfp4` | MXFP4 | `gemma4` | yes | yes | PROVEN | PROVEN | PROVEN | PROVEN | PARTIAL | PROVEN | PROVEN complete / PARTIAL side-effect | TODO | TODO | PARTIAL | PARTIAL |
| `osaurusai--gemma-4-e2b-it-qat-jang_4m` | JANG_4M | `gemma4` | yes | yes | PROVEN | PROVEN | PROVEN | PROVEN | PARTIAL | PROVEN | PROVEN complete / PARTIAL side-effect | PROVEN API | BLOCKED policy | PROVEN API / TODO UI | PARTIAL |
| `osaurusai--gemma-4-e4b-it-qat-mxfp4` | MXFP4 | `gemma4` | yes | yes | PROVEN | PROVEN agent | PROVEN agent | PROVEN agent | PARTIAL | TODO | PROVEN forced complete | TODO | TODO | TODO | PARTIAL |
| `osaurusai--gemma-4-e4b-it-qat-jang_4m` | JANG_4M | `gemma4` | yes | yes | PROVEN | PROVEN agent | PROVEN agent | PROVEN agent | PARTIAL | TODO | PROVEN forced complete | TODO | TODO | TODO | PARTIAL |
| `osaurusai--gemma-4-12b-it-qat-mxfp4` | MXFP4 | `gemma4_unified` | yes | yes | PROVEN | PROVEN agent | PROVEN agent | PROVEN agent | PARTIAL | TODO | PROVEN forced complete | TODO | TODO | TODO | PARTIAL |
| `osaurusai--gemma-4-12b-it-qat-jang_4m` | JANG_4M | `gemma4_unified` | yes | yes | PROVEN | PROVEN agent | PROVEN agent | PROVEN agent | PARTIAL | TODO | PROVEN forced complete | TODO | TODO | TODO | PARTIAL |
| `osaurusai--gemma-4-26b-a4b-it-qat-mxfp4` | MXFP4 | `gemma4` | yes | no | PROVEN | PROVEN agent | PROVEN agent | PROVEN agent | PARTIAL | TODO | PROVEN forced complete | TODO | N/A | TODO | PARTIAL |
| `osaurusai--gemma-4-26b-a4b-it-qat-jang_4m` | JANG_4M | `gemma4` | yes | no | PROVEN | PROVEN agent | PROVEN agent | PROVEN agent | PARTIAL | TODO | PROVEN forced complete | TODO | N/A | TODO | PARTIAL |
| `osaurusai--gemma-4-31b-it-qat-mxfp4` | MXFP4 | `gemma4` | yes | no | PROVEN | PROVEN agent | PROVEN agent | PROVEN agent | PARTIAL | TODO | PROVEN forced complete | TODO | N/A | TODO | PARTIAL |
| `osaurusai--gemma-4-31b-it-qat-jang_4m` | JANG_4M | `gemma4` | yes | no | PROVEN | PROVEN agent | PROVEN agent | PROVEN agent | PARTIAL | TODO | PROVEN forced complete | TODO | N/A | TODO | PARTIAL |

Current evidence behind non-TODO cells:

- Current app launch, vMLX `a4aa133` pin, keychain-disabled LaunchServices path:
  `/tmp/osaurus-keychain-free-gemma-checkpoint-a4aa-20260611-182816/models.json`.
- Current runtime settings from the isolated test root:
  `/tmp/osaurus-keychain-free-gemma-checkpoint-20260611-182534/config/server-runtime.json`
  has `pagedKV.enabled=false`, `blockDisk.enabled=true`,
  `legacyDisk.enabled=false`, `prefix.enabled=true`, and
  `liveKVCodec="engine_selected"`.
- E2B MXFP4 direct tool rows on the current app:
  `/tmp/osaurus-gemma-proof/chat-mxfp4-tool-forced-checkpoint-a4aa-exact.json`
  and
  `/tmp/osaurus-gemma-proof/chat-mxfp4-tool-result-continuation-checkpoint-a4aa.json`.
  The non-deterministic no-temperature probe
  `/tmp/osaurus-gemma-proof/chat-mxfp4-tool-forced-checkpoint-a4aa.json`
  produced malformed visible text instead of `tool_calls`; keep deterministic
  tool-proof requests at `temperature=0` until the default-sampler behavior is
  separately characterized.
- E2B JANG_4M direct tool rows on the current app:
  `/tmp/osaurus-gemma-proof/chat-jang4m-tool-forced-checkpoint-a4aa.json`
  and
  `/tmp/osaurus-gemma-proof/chat-jang4m-tool-result-continuation-checkpoint-a4aa.json`.
- Agent-route tool-surface fix on current PR branch:
  - Root issue: `/agents/{id}/run` rendered the agent prompt through
    `SystemPromptComposer`, but then discarded the composer-resolved tool
    surface and sent bare `ToolRegistry.alwaysLoadedSpecs`. That let the model
    prompt and actual tool schema diverge for default-agent configure tools and
    custom-agent gated tools. Strict OpenAI `/chat/completions` remains bare and
    stateless by design.
  - Source regression:
    `/tmp/osaurus-gemma-proof/xcode-test-http-agent-tool-surface.log` reports
    `** TEST SUCCEEDED **`; `agentRun_usesComposerResolvedToolSurface` proves
    the default-agent route receives exactly
    `ToolRegistry.defaultAgentAllowedToolNames`, while custom agents do not see
    default-agent-only `osaurus_*` configure tools.
  - Unsigned patched app build:
    `/tmp/osaurus-gemma-proof/xcode-build-debug-app-agenttool-surface.log`
    reports `** BUILD SUCCEEDED **`.
  - Patched app isolated root:
    `/tmp/osaurus-gemma-proof/agenttool-surface-root.txt`; health artifact
    `/tmp/osaurus-gemma-proof/agenttool-surface-health-after-status.json`
    reports `status=healthy`, `current_model=osaurusai--gemma-4-e2b-it-qat-jang_4m`,
    `local_model_scan.model_count=27`, persistence not degraded, and RAM
    feasibility `verdict="ok"`.
  - Live default-agent JANG_4M configure-read row:
    `/tmp/osaurus-gemma-proof/agenttool-surface-defaultagent-jang4m-status.sse`
    returned clean visible text through `/agents/00000000-0000-0000-0000-000000000001/run`
    with no marker/control-character leakage. It summarized the tool-visible
    installed-model count as `1`; `/health` separately reported raw local
    folder scan count `27`, so keep those counters distinct.
  - Live default-agent JANG_4M `complete` row:
    `/tmp/osaurus-gemma-proof/agenttool-surface-defaultagent-jang4m-complete.sse`
    returned `Patched default agent complete tool executed cleanly` with
    `finish_reason="stop"` and no protocol-marker leakage.
  - Live default-agent MXFP4 `complete` row:
    `/tmp/osaurus-gemma-proof/agenttool-surface-defaultagent-mxfp4-complete.sse`
    returned `Patched default agent mxfp4 complete tool executed cleanly` with
    `finish_reason="stop"` and no protocol-marker leakage. Health artifact
    `/tmp/osaurus-gemma-proof/agenttool-surface-health-after-mxfp4.json`
    reports `current_model=osaurusai--gemma-4-e2b-it-qat-mxfp4`, persistence
    not degraded, and RAM feasibility `verdict="ok"`.
  - L2 disk prefix cache artifacts were written under the isolated root:
    `cache/kv_v2` was 37 MB with three `.safetensors` files after the live
    default-agent rows.
- Follow-up forced-tool proof on patched app after the Gemma-only agent-loop
  directive fix:
  - Focused source regression:
    `/tmp/osaurus-gemma-proof/xcode-test-mlx-batch-agenttool-fix.log`
    reports `** TEST SUCCEEDED **` for `MLXBatchAdapterTests`, including
    `forcedToolChoiceAddsGemmaRequestLocalDirective` and the non-Gemma no-op
    guard.
  - Unsigned Debug app build:
    `/tmp/osaurus-gemma-proof/xcode-build-debug-app-agenttool-fix.log`
    reports `** BUILD SUCCEEDED **`.
  - Runtime defaults from isolated app root
    `/tmp/osaurus-keychain-free-gemma-agenttool-fix-open-a4aa-20260611-192622/config/server-runtime.json`
    keep `pagedKV.enabled=false`, `blockDisk.enabled=true`,
    `legacyDisk.enabled=false`, `prefix.enabled=true`,
    `liveKVCodec="engine_selected"`, `memorySafety.mode="safe_auto"`, and
    `memorySafety.allowExperimentalMLXPress=false`.
  - Direct `/v1/chat/completions` streaming tool proof:
    `/tmp/osaurus-gemma-proof/v1-stream-e2b-jang4m-forced-complete-agenttool-fix.sse`
    and
    `/tmp/osaurus-gemma-proof/v1-stream-e2b-mxfp4-forced-complete-agenttool-fix.sse`
    both emit `osaurus_prefill` queued/running/complete chunks, exact
    `complete` tool names, exact JSON `summary` arguments, and
    `finish_reason="tool_calls"`.
  - Agent-loop forced `complete` proof:
    `/tmp/osaurus-gemma-proof/agenttool-custom-e2b-jang4m-forced-complete-agenttool-fix.sse`
    returns the terminal `complete` summary cleanly through the Osaurus agent
    SSE surface with no protocol-marker leakage and no loop. The route hides
    raw tool invocations by design, so this remains `PARTIAL` agent proof
    until a side-effecting built-in tool row succeeds and is externally
    queryable.
  - Agent-loop DB side-effect attempt:
    `/tmp/osaurus-gemma-proof/agenttool-custom-e2b-jang4m-db-create-auto.sse`
    reached a DB-tool result path but failed on invalid model-produced column
    arguments; no table side effect was proven. Keep this as a blocker for
    exhaustive agent tool proof, not a pass.
  - Post-run cache/RAM proof:
    `/tmp/osaurus-gemma-proof/agenttool-fix-cache-after-agent-runs.json`
    has `disk_l2_hits=1`, `block_disk_store.hits=1`, `paged_hits=0`,
    `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
    `requires_disk_backed_restore=true`, `mlx_press.enabled=false`, and
    `memory_safety.verdict`/health equivalent `ok`. RSS sample
    `/tmp/osaurus-gemma-proof/agenttool-fix-ps-after-agent-runs.txt`
    records about 1.87 GB RSS after live JANG agent/direct rows.
- Current-tree default-agent tool trace proof from the rebuilt Debug app:
  - Follow-up root issue found 2026-06-11:
    `/agents/{id}/run` tool execution was proven, but ordinary local streams
    kept the sanitized `osaurus_agent_tool` progress chunks hidden behind the
    `X-Osaurus-Debug-Agent-Tools` header. That made the Osaurus UI/API blind
    during tool execution even though the model and tool loop were working.
  - Source regression after the visibility fix:
    `/tmp/osaurus-gemma-proof/xcode-green-agent-tool-visible-default.log`
    reports `** TEST SUCCEEDED **` for
    `agent_run_executes_tool_without_streaming_internal_sentinels`. The test
    sends no `X-Osaurus-Debug-Agent-Tools` header and now requires sanitized
    `osaurus_agent_tool` chunks with `choices: []`, `started`, `completed`,
    tool name `complete`, and no U+FFFE sentinel leakage.
  - Rebuilt app proof:
    `/tmp/osaurus-gemma-proof/xcode-build-debug-app-agent-tool-visible-default.log`
    reports `** BUILD SUCCEEDED **`. Older artifact
    `/tmp/osaurus-gemma-proof/xcode-build-debug-app-agenttrace.log` reports
    `** BUILD SUCCEEDED **`; the app launched with
    `OSU_MODELS_DIR=/Users/eric/models`, keychain disabled, and health artifact
    `/tmp/osaurus-gemma-proof/health-agenttool-visible.json` reporting
    `status=healthy`, `local_model_scan.model_count=27`, and persistence not
    degraded.
  - Product-gap repro before the fix:
    `/tmp/osaurus-gemma-proof/agents-default-12b-jang4m-c68c3c05-ordinary.sse`
    had no `osaurus_agent_tool` chunks, while
    `/tmp/osaurus-gemma-proof/agents-default-12b-jang4m-c68c3c05-debugtrace.sse`
    contained the same tool's started/completed chunks only because the debug
    header was present.
  - Live no-debug-header proof after the fix:
    `/tmp/osaurus-gemma-proof/agents-defaultuuid-12b-jang4m-agenttool-visible-uncommitted.sse`
    calls the built-in Default agent UUID route
    `/agents/00000000-0000-0000-0000-000000000001/run` with no debug header and
    contains two `osaurus_agent_tool` chunks for tool `complete`, phases
    `started` and `completed`, `finish_reason="stop"`, and no U+FFFE,
    `<|tool`, or `<tool_call` leakage.
  - Live no-debug-header cache/RAM proof after the fix:
    `/tmp/osaurus-gemma-proof/agents-defaultuuid-12b-jang4m-agenttool-visible-uncommitted-cache-after.json`
    reports `models[0].name=osaurusai--gemma-4-12b-it-qat-jang_4m`
    with `is_current=true`,
    `effective_kv_mode="turbo(3,3)"`, `memory_safety.cache.paged_kv_enabled=false`,
    `block_disk_store.enabled=true`, `block_disk_store.stores=1`,
    `disk_l2_stores=1`, `cache_topology.kv_layer_count=8`,
    `cache_topology.rotating_kv_layer_count=40`, and
    `cache_topology.requires_disk_backed_restore=true`. RSS sample
    `/tmp/osaurus-gemma-proof/agents-defaultuuid-12b-jang4m-agenttool-visible-uncommitted-ps-after.txt`
    records about 6.81 GB RSS for the dev app process after the row.
  - Current-head forced agent-loop proof on commit `5a885570`:
    `/tmp/osaurus-gemma-proof/xcode-build-debug-app-5a885570-agentproof.log`
    reports `** BUILD SUCCEEDED **`; app health
    `/tmp/osaurus-gemma-proof/health-agentproof-5a885570.json` reports
    `status=healthy`, `local_model_scan.model_count=27`, and
    `root="/Users/eric/models"`.
  - 12B JANG_4M actual agent-loop tool execution on commit `5a885570`:
    request
    `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-forced-complete-5a885570.request.json`
    calls `/agents/00000000-0000-0000-0000-000000000001/run` with
    `tool_choice=complete` and no debug header. Stream artifact
    `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-forced-complete-5a885570.sse`
    contains two `osaurus_agent_tool` chunks for `complete`, phases
    `started` and `completed`, `is_error=false`, `end_run=true`,
    `finish_reason="stop"`, the expected summary
    `12b jang4m agent loop tool execution proven on current PR head`, and no
    U+FFFE, `<|tool`, `<tool_call`, `<tool_response`, or chat-template marker
    leakage. Repeat artifact
    `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-forced-complete-repeat-5a885570.sse`
    passes the same leak/tool checks.
  - 12B JANG_4M cache/RAM proof on the repeated agent-loop row:
    `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-forced-complete-repeat-5a885570.cache.json`
    reports `models[0].name=osaurusai--gemma-4-12b-it-qat-jang_4m`,
    `effective_kv_mode="turbo(3,3)"`, `paged_kv_enabled=false`,
    `block_disk_store.enabled=true`, `disk_l2_hits=1`,
    `block_disk_store.hits=1`, `cache_topology.kv_layer_count=8`,
    `cache_topology.rotating_kv_layer_count=40`, and
    `requires_disk_backed_restore=true`. Wall-clock artifact
    `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-forced-complete-repeat-5a885570.timing.json`
    plus the parsed run recorded about 5.86 seconds for the repeated agent
    route. RSS sample
    `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-forced-complete-repeat-5a885570.ps.txt`
    records about 6.81 GB RSS.
  - 12B MXFP4 actual agent-loop tool execution on commit `5a885570`:
    request
    `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-forced-complete-5a885570.request.json`
    calls the same built-in Default agent route with `tool_choice=complete`.
    Stream artifact
    `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-forced-complete-5a885570.sse`
    contains two `osaurus_agent_tool` chunks for `complete`, phases
    `started` and `completed`, `is_error=false`, `end_run=true`,
    `finish_reason="stop"`, the expected summary
    `12b mxfp4 agent loop tool execution proven on current PR head`, and no
    U+FFFE, `<|tool`, `<tool_call`, `<tool_response`, or chat-template marker
    leakage. Repeat artifact
    `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-forced-complete-repeat-5a885570.sse`
    passes the same leak/tool checks.
  - 12B MXFP4 cache/RAM proof on the repeated agent-loop row:
    `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-forced-complete-repeat-5a885570.cache.json`
    reports `models[0].name=osaurusai--gemma-4-12b-it-qat-mxfp4`,
    `effective_kv_mode="turbo(3,3)"`, `paged_kv_enabled=false`,
    `block_disk_store.enabled=true`, `disk_l2_hits=1`,
    `block_disk_store.hits=1`, `cache_topology.kv_layer_count=8`,
    `cache_topology.rotating_kv_layer_count=40`, and
    `requires_disk_backed_restore=true`. Wall-clock artifact
    `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-forced-complete-repeat-5a885570.timing.json`
    plus the parsed run recorded about 5.68 seconds for the repeated agent
    route. RSS sample
    `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-forced-complete-repeat-5a885570.ps.txt`
    records about 0.56 GB RSS after switching from 12B JANG_4M to 12B MXFP4.
  - Current-head rebuilt matrix proof on commit `e9c3daed`:
    `/tmp/osaurus-gemma-proof/xcode-build-debug-app-e9c3daed-matrix.log`
    reports `** BUILD SUCCEEDED **`; app health
    `/tmp/osaurus-gemma-proof/health-matrix-e9c3daed.json` reports
    `status=healthy`, `local_model_scan.model_count=27`, and
    `root="/Users/eric/models"`.
  - Remaining beyond-E2B forced agent-loop matrix:
    `/tmp/osaurus-gemma-proof/agent-matrix-e9c3daed-summary.txt` has
    `pass_ok=true` for first and repeat `/agents/{defaultUUID}/run`
    `tool_choice=complete` rows on E4B JANG_4M, E4B MXFP4, 26B-A4B JANG_4M,
    26B-A4B MXFP4, 31B JANG_4M, and 31B MXFP4. Every row has two
    `osaurus_agent_tool` chunks, phases `started` and `completed`, tool name
    `complete`, `finish_reason="stop"`, the exact expected summary, and no
    U+FFFE, `<|tool`, `<tool_call`, `<tool_response`, or chat-template marker
    leakage.
  - Remaining beyond-E2B cache/RAM matrix:
    the repeat rows in
    `/tmp/osaurus-gemma-proof/agent-matrix-e9c3daed-summary.txt` report
    `effective_kv_mode="turbo(3,3)"`, `paged=false`,
    `block_hits=1`, `block_stores=1`, `disk_l2_hits=1`, and
    `restore=true` for each model. Layer topology by row:
    E4B = `kv_layers=4`, `rotating_layers=20`; 26B-A4B =
    `kv_layers=5`, `rotating_layers=25`; 31B = `kv_layers=10`,
    `rotating_layers=50`. RSS samples in the same summary range from about
    0.58-0.95 GB for MXFP4 rows to about 2.89 GB (E4B JANG_4M),
    13.69 GB (26B-A4B JANG_4M), and 17.39 GB (31B JANG_4M). These are still
    RSS samples, not lower-spec Activity Monitor physical-footprint proof.
  - Default-agent JANG_4M end-run tool proof:
    `/tmp/osaurus-gemma-proof/agents-default-jang4m-complete-trace.sse`
    contains trace chunks for tool `complete` with phases `started` and
    `completed`, `is_error=false`, `end_run=true`, then the exact visible final
    text `Default agent JANG4M tool execution traced through Osaurus dev app.`
  - Default-agent JANG_4M cache/RAM proof:
    `/tmp/osaurus-gemma-proof/cache-after-agents-default-jang4m-complete-trace.json`
    reports current model `osaurusai--gemma-4-e2b-it-qat-jang_4m`,
    `effective_kv_mode="turbo(3,3)"`, `paged_cache.enabled=false`,
    `block_disk_store.enabled=true`, `disk_l2_stores=1`,
    `kv_layer_count=3`, `rotating_kv_layer_count=12`,
    `requires_disk_backed_restore=true`, `memory_safety.allowed=true`, and
    RSS about 2.03 GB.
  - Default-agent MXFP4 end-run tool proof:
    `/tmp/osaurus-gemma-proof/agents-default-mxfp4-complete-trace.sse`
    contains trace chunks for tool `complete` with phases `started` and
    `completed`, `is_error=false`, `end_run=true`, then the exact visible final
    text `Default agent MXFP4 tool execution traced through Osaurus dev app.`
  - Default-agent MXFP4 cache/RAM proof:
    `/tmp/osaurus-gemma-proof/cache-after-agents-default-mxfp4-complete-trace.json`
    reports current model `osaurusai--gemma-4-e2b-it-qat-mxfp4`,
    `effective_kv_mode="turbo(3,3)"`, `paged_cache.enabled=false`,
    `block_disk_store.enabled=true`, `kv_layer_count=3`,
    `rotating_kv_layer_count=12`, `requires_disk_backed_restore=true`,
    `memory_safety.allowed=true`, and RSS about 0.61 GB.
  - Exact-copy status-tool rows are not counted as a full pass:
    `/tmp/osaurus-gemma-proof/agents-default-jang4m-osaurus-status.sse` and
    `/tmp/osaurus-gemma-proof/agents-default-mxfp4-osaurus-status.sse` reached
    terminal text but the model visibly mangled copied words/numbers. Keep
    those rows `PARTIAL` and use them as a regression note for exact-copy
    quality; they do not invalidate the traced `complete` tool execution pass.
  - Expanded QAT default-agent trace matrix:
    `/tmp/osaurus-gemma-proof/agenttrace-matrix-summary-20260611T205423Z.txt`
    proves `complete` end-run tool traces for E4B JANG_4M, E4B MXFP4, 12B
    JANG_4M, 12B MXFP4, and 26B-A4B JANG_4M. Each passing row reports
    `trace=True`, `final=True`, `finish_stop=True`, matching current model,
    `effective_kv_mode="turbo(3,3)"`, `paged=false`, `disk=true`, and RSS:
    E4B JANG_4M 3.16 GB, E4B MXFP4 0.74 GB, 12B JANG_4M 7.45 GB, 12B MXFP4
    0.75 GB, and 26B-A4B JANG_4M 13.69 GB. These are agent-loop tool trace
    passes, not full harness/VL/audio passes.
  - Expanded matrix blocked rows:
    26B-A4B MXFP4 failed with `curl_failed=18`, then the dev app crashed before
    31B rows could run; both 31B JANG_4M and 31B MXFP4 have `curl_failed=7`
    because the server was already down. The zero-byte/partial SSE artifacts
    are:
    `/tmp/osaurus-gemma-proof/agents-default-osaurusai-gemma-4-26b-a4b-it-qat-mxfp4-complete-trace.sse`,
    `/tmp/osaurus-gemma-proof/agents-default-osaurusai-gemma-4-31b-it-qat-jang-4m-complete-trace.sse`,
    and
    `/tmp/osaurus-gemma-proof/agents-default-osaurusai-gemma-4-31b-it-qat-mxfp4-complete-trace.sse`.
  - Crash root-cause evidence:
    `/Users/eric/Library/Logs/DiagnosticReports/osaurus-2026-06-11-205528.ips`
    is an `EXC_BAD_ACCESS` / `SIGSEGV` crash on a cooperative queue. The
    stack is MLX Metal dispatch through
    `Model2VecStaticEmbeddingPipeline.embedOne`, `VMLXModel2VecEmbedder`,
    `MetalSafeEmbedder`, `HybridSearchEngine.search`, and
    `MemorySearchService.searchTranscript`. This points at resident local
    model inference plus vMLX Model2Vec memory vector search, not Gemma decode
    or the QAT bundle loader.
  - Crash prevention guard added after the IPS:
    `MemorySearchService` now skips VecturaKit/vMLX vector indexing and search
    while any local MLX model is resident, or when
    `OSAURUS_DISABLE_MEMORY_VECTOR_SEARCH=1/true`, and uses the existing SQL
    text fallback instead. This is a fail-closed Osaurus guard for the
    checkpoint, not the final vMLX Model2Vec root fix. Vector memory search can
    be restored during resident local inference only after the vMLX embedding
    crash path is fixed and live-proven.
  - Guard verification:
    `/tmp/osaurus-gemma-proof/xcode-test-memory-vector-guard.log` reports
    `** TEST SUCCEEDED **` for `MemorySearchServiceTests`, and
    `/tmp/osaurus-gemma-proof/xcode-test-runtime-policy-memory-vector-guard.log`
    reports `** TEST SUCCEEDED **` with 84 `RuntimePolicySourceTests` passing,
    including the source-policy assertion that all memory vector operations are
    guarded before VecturaKit/vMLX embedding work.
  - Guarded-app build proof:
    `/tmp/osaurus-gemma-proof/xcode-build-debug-app-memory-vector-guard.log`
    reports `** BUILD SUCCEEDED **`.
  - Guarded-app launch proof:
    `/tmp/osaurus-gemma-proof/osaurus-launch-debug-foreground.log` shows the
    Debug app launched keychain-free with the local server bound on
    `127.0.0.1:1337`. Health artifact
    `/tmp/osaurus-gemma-proof/health-memory-vector-guard-foreground.json`
    reports `status=healthy`, `local_model_scan.model_count=27`, and
    `root="/Users/eric/models"`.
  - Retried 26B-A4B MXFP4 after the memory-vector guard:
    `/tmp/osaurus-gemma-proof/agents-default-osaurusai-gemma-4-26b-a4b-it-qat-mxfp4-complete-trace-memoryguard.sse`
    contains `osaurus_agent_tool` `started` and `completed` chunks for
    `complete`, `is_error=false`, `end_run=true`, exact final text, and
    `finish_reason="stop"`. Cache artifact
    `/tmp/osaurus-gemma-proof/cache-after-agents-default-osaurusai-gemma-4-26b-a4b-it-qat-mxfp4-complete-trace-memoryguard.json`
    reports current model
    `osaurusai--gemma-4-26b-a4b-it-qat-mxfp4`,
    `effective_kv_mode="turbo(3,3)"`, `paged_cache.enabled=false`,
    `block_disk_store.enabled=true`, `kv_layer_count=5`,
    `rotating_kv_layer_count=25`, and
    `requires_disk_backed_restore=true`.
  - Retried 31B JANG_4M after the memory-vector guard:
    `/tmp/osaurus-gemma-proof/agents-default-osaurusai-gemma-4-31b-it-qat-jang-4m-complete-trace-memoryguard.sse`
    contains the same passing `complete` trace and final text. Cache artifact
    `/tmp/osaurus-gemma-proof/cache-after-agents-default-osaurusai-gemma-4-31b-it-qat-jang-4m-complete-trace-memoryguard.json`
    reports `effective_kv_mode="turbo(3,3)"`, paged cache off, block disk
    enabled, `kv_layer_count=10`, `rotating_kv_layer_count=50`, and
    disk-backed restore required. RSS sample
    `/tmp/osaurus-gemma-proof/ps-after-agents-default-osaurusai-gemma-4-31b-it-qat-jang-4m-complete-trace-memoryguard.txt`
    records about 18.10 GB RSS after the 31B JANG_4M row.
  - Retried 31B MXFP4 after the memory-vector guard:
    `/tmp/osaurus-gemma-proof/agents-default-osaurusai-gemma-4-31b-it-qat-mxfp4-complete-trace-memoryguard.sse`
    contains the same passing `complete` trace and final text. Cache artifact
    `/tmp/osaurus-gemma-proof/cache-after-agents-default-osaurusai-gemma-4-31b-it-qat-mxfp4-complete-trace-memoryguard.json`
    reports `effective_kv_mode="turbo(3,3)"`, paged cache off, block disk
    enabled, `kv_layer_count=10`, `rotating_kv_layer_count=50`, and
    disk-backed restore required. Health artifact
    `/tmp/osaurus-gemma-proof/health-after-31b-mxfp4-memoryguard.json`
    reports the app still healthy with current model
    `osaurusai--gemma-4-31b-it-qat-mxfp4`, RAM feasibility `verdict="ok"`,
    and `mlx_last_error=null`.
- E2B JANG_4M API prefill progress on the current app:
  `/tmp/osaurus-gemma-proof/chat-jang4m-prefill-long-checkpoint-a4aa.sse`
  emitted 19 `osaurus_prefill` chunks from queued/running through
  `complete 8702/8702 decode_ready` before the first content token; repeat
  proof is
  `/tmp/osaurus-gemma-proof/chat-jang4m-prefill-long-repeat-checkpoint-a4aa.sse`.
- E2B JANG_4M Prefix/L2 and TQ/SWA on the current app:
  `/tmp/osaurus-gemma-proof/cache-after-prefill-repeat-checkpoint-a4aa.json`
  has `disk_l2_hits=1`, `block_disk_store.hits=1`,
  `paged_hits=0`, `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
  `kv_layer_count=3`, `rotating_kv_layer_count=12`, and
  `requires_disk_backed_restore=true`. Longer decode proof in
  `/tmp/osaurus-gemma-proof/cache-after-long-decode-tq-checkpoint-a4aa.json`
  records `batch_diagnostics.turbo_quant_compressions=3`.
- E2B JANG_4M real VL image row on commit `e9c3daed`:
  deterministic input image
  `/tmp/osaurus-gemma-proof/red-square-32.png` is a 32x32 red PNG carried in
  `/tmp/osaurus-gemma-proof/vl-e2b-jang4m-red-square-e9c3daed.request.json`
  as an OpenAI-compatible `image_url` data URL. First and repeat SSE artifacts
  `/tmp/osaurus-gemma-proof/vl-e2b-jang4m-red-square-first-e9c3daed.sse` and
  `/tmp/osaurus-gemma-proof/vl-e2b-jang4m-red-square-repeat-e9c3daed.sse`
  both return the visible answer `Red`, `finish_reason="stop"`, three
  `osaurus_prefill` chunks, and no U+FFFE/tool/template marker leakage.
  Repeat cache artifact
  `/tmp/osaurus-gemma-proof/vl-e2b-jang4m-red-square-repeat-e9c3daed.cache.json`
  reports `effective_kv_mode="turbo(3,3)"`, `paged_kv_enabled=false`,
  `block_disk_store.enabled=true`, `disk_l2_hits=1`, `kv_layer_count=3`,
  `rotating_kv_layer_count=12`, and disk-backed restore required. The repeat
  row completed in about 1.87 seconds wall clock versus about 4.75 seconds on
  the first row.
- E2B JANG_4M real audio row on commit `e9c3daed`:
  deterministic input audio
  `/tmp/osaurus-gemma-proof/tone-440hz-1s.wav` is a 1-second 440 Hz WAV carried
  in `/tmp/osaurus-gemma-proof/audio-e2b-jang4m-tone-e9c3daed.request.json`
  as OpenAI-compatible `input_audio`. Artifacts
  `/tmp/osaurus-gemma-proof/audio-e2b-jang4m-tone-first-e9c3daed.sse` and
  `/tmp/osaurus-gemma-proof/audio-e2b-jang4m-tone-repeat-e9c3daed.sse` do not
  prove audio generation; both fail closed with the typed SSE error:
  `Gemma4 audio input is not enabled because the pinned vMLX Gemma4 runtime
  does not wire audio_tower/embed_audio yet.` Keep Gemma4 audio `BLOCKED
  policy` until vMLX wires the real audio tower/embed path and the row is
  rerun successfully.
- E2B MXFP4 Prefix/L2 and TQ/SWA on the current app:
  `/tmp/osaurus-gemma-proof/cache-after-mxfp4-long-decode-repeat-checkpoint-a4aa.json`
  has `disk_l2_hits=1`, `block_disk_store.hits=1`,
  `paged_hits=0`, `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
  `kv_layer_count=3`, `rotating_kv_layer_count=12`, and
  `requires_disk_backed_restore=true`; its batch diagnostics record
  `turbo_quant_compressions=2` after the repeated long-decode row.
- Static per-model cache topology still reports
  `turbo_quant_kv_layer_count=0` because the topology snapshot records the
  base cache class layout. Use `batch_diagnostics.turbo_quant_compressions`
  plus `effective_kv_mode` for live TurboQuant activity until telemetry is
  extended to expose post-conversion layer counts.
- Current RSS samples:
  `/tmp/osaurus-gemma-proof/ps-after-tool-continuations-checkpoint-a4aa.txt`
  recorded about 1.96 GB RSS after E2B tool rows. Physical footprint still
  needs Activity Monitor/lower-spec teammate proof.
- Current-tree Agent route proof after the `a4aa133` repin is still
  `PARTIAL`, but no longer blocked on schema mismatch: focused source tests
  now prove the hidden agent route uses the composer-resolved default/custom
  tool surface, and live default-agent JANG_4M rows for `osaurus_status` and
  `complete` return clean terminal text. The route intentionally hides raw tool
  invocations from SSE; DB side-effect proof previously failed argument
  validation. Do not mark the full UI/agent-loop row complete until a real
  Chat UI run or independently queryable side-effect row is captured.
- Speed is still `PARTIAL` for proven E2B rows because token/s is present, but
  TTFT is not yet consistently recorded as a first-class metric across the
  matrix. Add timestamp-based TTFT extraction or explicit runtime TTFT before
  marking `Speed` proven.
- Memory is still `PARTIAL` because RSS samples exist, but final checkpoint
  needs Activity Monitor physical-footprint samples on lower-spec Macs.

Checkpoint execution order:

1. Keep the QAT app path buildable and live-proven first; do not widen into
   unrelated model families or non-QAT bundles.
2. Run the smallest rows first: E2B MXFP4 and E2B JANG_4M full matrix, then
   E4B, then 12B, then 26B-A4B and 31B as local RAM allows.
3. For each model, collect one artifact bundle prefix:
   `/tmp/osaurus-gemma-proof/matrix-<model>-<date>-{request,sse,response,cache,ps}.<ext>`.
4. After each model, update the table above before moving to the next model.
5. Run the QAT harness rows, record scores, and fix score blockers before
   merge-ready wording.
6. Only after the QAT matrix has app-facing proof and harness scores should the
   team checkpoint be merged/pushed for lower-spec Mac testing.

## Current Verification

- vMLX branch `codex/cache-defaults-bf16-qat` is pushed at
  `a4aa133689417b924833610db0ff2732151d74cd`.
- vMLX dependency flattening is now part of that SHA:
  `Libraries/MLXEmbedders/Model2VecStaticEmbeddingPipeline.swift` adds a
  vMLX-native Model2Vec/static embedding path for bundles such as
  `minishlab/potion-base-4M`.
- Osaurus is pinned to vMLX `a4aa133689417b924833610db0ff2732151d74cd` and
  VecturaKit `3bc52538f16a95d956c575abbc7e0423737dfd64`.
- The Osaurus embedding stack no longer imports VecturaKit's old
  `SwiftEmbedder` path. `EmbeddingService` now uses a lazy
  `VMLXModel2VecEmbedder` through `MetalSafeEmbedder`, backed by vMLX
  `MLXEmbedders`.
- Xcode and SwiftPM dependency graphs are flattened for the app path:
  `Packages/OsaurusCore/Package.resolved`,
  `osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved`, and
  `App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  no longer contain `swift-embeddings`, external `swift-transformers`,
  `swift-safetensors`, or external `swift-huggingface`. They contain
  `vmlx-swift` at `a4aa133` and VecturaKit at `3bc5253`.
- Build proof after flattening:
  - vMLX full build:
    `/tmp/osaurus-gemma-proof/vmlx-build-full-model2vec.log`
    reports `Build complete!`.
  - OsaurusCore SwiftPM build:
    `/tmp/osaurus-gemma-proof/swift-build-core-vmlx-model2vec-vectura6.log`
    reports `Build complete!`.
  - Xcode workspace resolve:
    `/tmp/osaurus-gemma-proof/xcode-resolve-vmlx-a4aa-vectura6.log`
    resolves `mlx-swift @ a4aa133` and `VecturaKit @ 3bc5253`.
  - Xcode app-project resolve:
    `/tmp/osaurus-gemma-proof/xcode-resolve-app-vmlx-a4aa-vectura6.log`
    resolves `mlx-swift @ a4aa133` and `VecturaKit @ 3bc5253`.
- Current keychain-free Debug app build proof after the `a4aa133` repin:
  `/tmp/osaurus-gemma-proof/xcode-build-debug-app-vmlx-a4aa-vectura6.log`
  reports `** BUILD SUCCEEDED **`.
- Current live Gemma proof after the `a4aa133` repin is recorded in the
  checkpoint proof matrix above. Older live artifacts below remain historical
  context only.
- Focused Xcode source regression proof after the `a4aa133` repin:
  `/tmp/osaurus-gemma-proof/xcode-test-focused-cache-prefill-a4aa.log`
  reports `** TEST SUCCEEDED **`. The xcresult bundle is
  `build/XcodeDerivedData-gemma-current-tests/Logs/Test/Test-OsaurusCoreTests-2026.06.11_18-36-32--0700.xcresult`.
  This covered `GenerationEventMapperTests`, `InferenceProgressManagerTests`,
  `ServerRuntimeSettingsStoreTests`, `MLXBatchAdapterTests`, and
  `HTTPHandlerChatStreamingTests`.
- Focused Xcode source regression rerun after removing non-QAT checkpoint
  scope:
  `/tmp/osaurus-gemma-proof/xcode-test-focused-cache-prefill-a4aa-rerun.log`
  reports `** TEST SUCCEEDED **` with 128 tests passing. The xcresult bundle is
  `/tmp/osaurus-gemma-proof/xcode-test-focused-cache-prefill-a4aa-rerun.xcresult`.
  This again covered cache default migration, prefill progress, streaming
  prefill diagnostics, token/s usage chunks, and Gemma tool-surface handling.
- SwiftPM focused test attempt is locally blocked by this machine's SwiftPM
  test toolchain failing to import module `Testing`; the blocker artifact is
  `/tmp/osaurus-gemma-proof/swift-test-focused-cache-prefill-a4aa.log`.
- Local `docs/HARNESS_COMPATIBILITY.md` has been restored from upstream main
  for the required AgentLoop/AgentLoopFrontier harness contract.
- Harness branch status: this branch predates the upstream AgentLoop harness
  implementation. `origin/main` adds the documented `AgentLoop`,
  `AgentLoopFrontier`, `SandboxFrontier`, `CapabilityClaims`, and
  `SandboxDiagnostics` suites, plus matching runner code such as
  `EvalRunnerAgentLoop.swift`. That runner depends on newer OsaurusCore
  agent-loop infrastructure including `AgentLoopEvaluator` and
  `CapabilityClaimsEvaluator`, so copying only the suite JSON or only
  `Packages/OsaurusEvals` into this cache/runtime branch would produce a
  broken partial port. The harness proof gate is therefore blocked until this
  PR is rebased/merged onto the upstream eval-harness stack or a narrow
  backport of the complete agent-loop evaluator stack is intentionally made.
- Local eval CLI dependency status: the earlier temporary VecturaKit 5.2.1 /
  `swift-embeddings` pin is superseded. The real root fix is to keep
  VecturaKit's core package provider-free and supply Model2Vec embeddings from
  vMLX. This removes the resolver fight between Osaurus's mirrored
  `swift-transformers` fork and `swift-embeddings` tags that require newer
  upstream transformer tags.
- Eval CLI proof after the dependency fix:
  `/tmp/osaurus-gemma-proof/osaurus-evals-help-vecturakit-521-swiftemb-targetdep.log`
  reports `Build of product 'osaurus-evals' complete!`.
- Local eval smoke after the dependency fix:
  - `/tmp/osaurus-gemma-proof/osaurus-evals-streaminghint-smoke-20260612.log`
    and `build/eval-reports/streaminghint-smoke-20260612.json` report
    `3 total · 3 passed · 0 failed · 0 skipped · 0 errored`.
  - `/tmp/osaurus-gemma-proof/osaurus-evals-gemma4-e2b-mxfp4-preflight-smalltalk-20260612.log`
    and
    `build/eval-reports/gemma4-e2b-mxfp4-preflight-smalltalk-20260612.json`
    report `1 total · 1 passed · 0 failed · 0 skipped · 0 errored` for
    `--model osaurusai--gemma-4-e2b-it-qat-mxfp4`. This is only an
    eval-runner/config smoke; the 1ms row does not prove Gemma generation or
    quality.
- Unsigned/keychain-free Debug app build succeeded:
  `build/XcodeDerivedData-gemma-streamdiag/Build/Products/Debug/osaurus.app`.
- Runtime settings before live proof:
  - `cache.pagedKV.enabled=false`
  - `cache.liveKVCodec="engine_selected"`
  - `cache.blockDisk.enabled=true`
  - `cache.legacyDisk.enabled=false`
- vMLX root fix for Osaurus agent tools:
  `MLXVLM/Models/Gemma4.swift` now normalizes `input.tools` through
  `MLXLMCommon.normalizedToolsForChatTemplate` before Gemma 4 renders the
  native chat template. This fixes the prior `/agents/{id}/run` failure:
  `Chat template error: Runtime error: upper filter requires string`.
- Live JANG_4M proof:
  - Fresh visible generation from the unsigned dev app:
    `/tmp/osaurus-gemma-proof/chat-jang4m-visible-swa-live.json` returned
    `Seven plus five equals twelve.`
  - Fresh long streaming row:
    `/tmp/osaurus-gemma-proof/chat-jang4m-visible-long-stream-swa-live.sse`
    returned `The final word is omega.` with usage
    `prompt_tokens=119`, `completion_tokens=6`.
  - `/agents/{id}/run` no longer hits the Gemma template error:
    `/tmp/osaurus-gemma-proof/agent-run-jang4m-forced-vmlxfix-sse.txt`
  - Direct OpenAI tool-call proof returns `finish_reason="tool_calls"`, tool
    `complete`, exact JSON args
    `{"summary":"qat jang4m direct tool ok verified through osaurus"}`:
    `/tmp/osaurus-gemma-proof/chat-tool-jang4m-forced-vmlxfix.json`
  - Cache telemetry after JANG agent route:
    `/tmp/osaurus-gemma-proof/cache-after-agent-run-jang4m-forced-vmlxfix.json`
    shows `effective_kv_mode="turbo(3,3)"`,
    `paged_cache.enabled=false`, `turbo_quant_compressions=4`,
    `kv_layer_count=3`, `rotating_kv_layer_count=12`, and
    `requires_disk_backed_restore=true`.
  - Fresh direct tool proof from the unsigned dev app:
    `/tmp/osaurus-gemma-proof/chat-jang4m-tool-forced-e8b5.json`
    returned tool `complete` with exact JSON args
    `{"summary":"qat jang4m e8b5 tool ok"}`.
  - Fresh tool-result continuation proof:
    `/tmp/osaurus-gemma-proof/chat-jang4m-tool-result-continuation-e8b5.json`
    returned visible text
    `The tool returned the summary: "qat jang4m e8b5 tool ok".`
  - Fresh SWA cache telemetry after tool continuation:
    `/tmp/osaurus-gemma-proof/cache-after-jang4m-tool-continuation-swa-live.json`
    shows `effective_kv_mode="turbo(3,3)"`,
    `paged_cache.enabled=false`, `turbo_quant_compressions=3`,
    `kv_layer_count=3`, `rotating_kv_layer_count=12`,
    `requires_disk_backed_restore=true`, and block disk enabled with stores.
- Live MXFP4 proof:
  - Fresh long streaming row from the unsigned dev app:
    `/tmp/osaurus-gemma-proof/chat-mxfp4-visible-long-stream-swa-live.sse`
    returned `The final word is gold.` with usage `prompt_tokens=95`,
    `completion_tokens=6`.
  - `/agents/{id}/run` loads and completes without the Gemma template error:
    `/tmp/osaurus-gemma-proof/agent-run-mxfp4-forced-vmlxfix-sse.txt`
  - Direct OpenAI tool-call proof returns `finish_reason="tool_calls"`, tool
    `complete`, exact JSON args
    `{"summary":"qat mxfp4 direct tool ok verified through osaurus"}`:
    `/tmp/osaurus-gemma-proof/chat-tool-mxfp4-forced-vmlxfix.json`
  - Cache telemetry after MXFP4 agent route:
    `/tmp/osaurus-gemma-proof/cache-after-mxfp4-agent-vmlxfix.json` shows
    `effective_kv_mode="turbo(3,3)"`, `paged_cache.enabled=false`,
    `turbo_quant_compressions=3`, `kv_layer_count=3`,
    `rotating_kv_layer_count=12`, and `requires_disk_backed_restore=true`.
  - RAM sample after MXFP4 live proof:
    `/tmp/osaurus-gemma-proof/ps-after-mxfp4-vmlxfix.txt` recorded
    `RSS=597056 KB` for the dev app process.
  - Fresh direct tool proof from the unsigned dev app:
    `/tmp/osaurus-gemma-proof/chat-mxfp4-tool-forced-e8b5.json`
    returned tool `complete` with exact JSON args
    `{"summary":"qat mxfp4 e8b5 tool ok"}`.
  - Fresh tool-result continuation proof:
    `/tmp/osaurus-gemma-proof/chat-mxfp4-tool-result-continuation-e8b5.json`
    returned visible text
    `The tool returned the summary "qat mxfp4 e8b5 tool ok".`
  - Fresh SWA cache telemetry after tool continuation:
    `/tmp/osaurus-gemma-proof/cache-after-mxfp4-tool-continuation-swa-live.json`
    shows `effective_kv_mode="turbo(3,3)"`,
    `paged_cache.enabled=false`, `turbo_quant_compressions=3`,
    `kv_layer_count=3`, `rotating_kv_layer_count=12`,
    `requires_disk_backed_restore=true`, and block disk enabled with stores.
  - RAM sample after the fresh MXFP4 proof:
    `/tmp/osaurus-gemma-proof/ps-after-tools-e8b5.txt`
    recorded `RSS=630480 KB` for the dev app process after JANG was unloaded
    and MXFP4 was current.
- vMLX added a focused Gemma SWA cache contract test: full-attention
  `KVCacheSimple` layers are TurboQuant-eligible, while sliding/SWA
  `RotatingKVCache` layers stay disk-backed.
- vMLX focused SwiftPM test attempt for that SWA contract is blocked before
  the filter runs by the existing local toolchain issue:
  `Tests/MLXPressPolicyTests/MLXPressLowRamPolicySourceTests.swift:4:8:
  error: no such module 'Testing'`.
- vMLX build proof for the final prefill-progress patch:
  `/tmp/osaurus-gemma-proof/vmlx-swift-build-solo-prefill-progress-4.log`
  reports `Build complete!` at SHA
  `e8b5ce989ff420447518a88dd1924d872fc37a35`.
- Osaurus test status:
  - `HTTPHandlerChatStreamingTests` now covers OpenAI-compatible streaming
    diagnostics. Red run before the fix:
    `/tmp/osaurus-gemma-proof/xcode-red-http-streaming-suite.log` failed
    `sse_path_uses_engine_stats_for_usage_chunk` and
    `sse_path_emits_prefill_progress_diagnostic_chunks`.
    Green run after the fix:
    `/tmp/osaurus-gemma-proof/xcode-green-http-streaming-suite.log` passed the
    full `HTTPHandlerChatStreamingTests` filter.
  - OpenAI SSE `stream_options.include_usage` now carries
    `usage.tokens_per_second` when the engine emits `StreamingStatsHint`.
  - OpenAI SSE now emits an Osaurus extension chunk with empty `choices` and
    top-level `osaurus_prefill` when the engine emits
    `StreamingPrefillProgressHint`. This lets Osaurus UI/API clients render
    determinate prefill progress without exposing the internal sentinel.
  - Focused cache/default/prefill/tool source tests are green after fixing the
    stale cache-default assertions:
    `/tmp/osaurus-gemma-proof/xcode-green-cache-prefill-focused-e8b5.log`
    reports `** TEST SUCCEEDED **` for `ServerRuntimeSettingsStoreTests`,
    `MLXBatchAdapterTests`, `StreamingHintTests`,
    `GenerationEventMapperTests`, `InferenceProgressManagerTests`,
    `RuntimePolicySourceTests`, `ToolSerializationStabilityTests`, and
    `MCPHTTPHandlerTests`. The log also verifies the workspace checkout of
    vMLX `e8b5ce989ff420447518a88dd1924d872fc37a35`.
  - The focused run caught a real paged-cache migration gap before green:
    old default-ish persisted rows with `liveKVCodec="none"` could keep
    `cache.pagedKV.enabled=true`. `ServerRuntimeSettingsStore` now repairs
    both old `none` and `engineSelected` default-ish rows to paged KV off while
    preserving the explicit live KV codec and block-disk L2 cache.
  - `xcodebuild build` for the dev app passes against the new vMLX pin.
  - The workspace `ToolSerializationStabilityTests` run initially exposed a
    bad test assertion: it treated a valid database-tool property named
    `type` as a non-string schema `type` field. The assertion is now narrowed
    to schema objects.
  - `swift test --filter ToolSerializationStabilityTests` is blocked in this
    environment by `no such module 'Testing'`, matching the known SwiftPM
    toolchain issue for packages using Apple's Testing module.
- Live app/API diagnostics proof from the freshly built Debug app:
  - Launched app:
    `build/XcodeDerivedData-gemma-streamdiag/Build/Products/Debug/osaurus.app`.
  - LaunchServices proof needed `OSU_MODELS_DIR=/Users/eric/models`; without
    it, the app stayed healthy but `/v1/models` was empty because the effective
    model directory resolved elsewhere.
  - `/tmp/osaurus-gemma-proof/models-streamdiag-modeldir-1337.json` advertised
    all ten requested OsaurusAI Gemma 4 QAT MXFP4/JANG_4M repos.
  - Token/s live API proof:
    `/tmp/osaurus-gemma-proof/chat-mxfp4-l2-repeat-first-streamdiag.sse`
    includes `usage.tokens_per_second=2.9493`, and
    `/tmp/osaurus-gemma-proof/chat-mxfp4-l2-repeat-second-streamdiag.sse`
    includes `usage.tokens_per_second=18.098`.
  - Prefill progress and L2 disk prefix/cache proof with paged RAM cache off:
    `/tmp/osaurus-gemma-proof/chat-mxfp4-l2-long-first-streamdiag.sse` and
    `/tmp/osaurus-gemma-proof/chat-mxfp4-l2-long-second-streamdiag.sse` used an
    exact long-prefix repeat on `osaurusai--gemma-4-e2b-it-qat-mxfp4`.
    `/tmp/osaurus-gemma-proof/cache-after-l2-long-repeat-streamdiag.json`
    reports `disk_l2_hits=1`, `disk_l2_stores=4`, `disk_l2_misses=6`,
    `paged_hits=0`, `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
    `turbo_quant_compressions=3`, `kv_layer_count=3`,
    `rotating_kv_layer_count=12`, and `requires_disk_backed_restore=true`.
  - Final e8b5 live prefill proof:
    `/tmp/osaurus-gemma-proof/chat-jang4m-prefill-long-e8b5.sse` emitted 13
    OpenAI-compatible `osaurus_prefill` chunks on the default single-batch
    solo path before the answer `done.`. The progress sequence included
    `queued`, `prefill/running`, 512-token chunk increments through 5120 /
    5423 units, and `complete/decode_ready`. The final usage chunk recorded
    `prompt_tokens=6496`, `completion_tokens=2`, and
    `tokens_per_second=0.5986`.
  - Final e8b5 cache telemetry for the same prefill row:
    `/tmp/osaurus-gemma-proof/cache-after-prefill-long-jang4m-e8b5.json`
    reports `disk_l2_hits=1`, `disk_l2_stores=1`, `paged_hits=0`,
    `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
    `turbo_quant_compressions=1`, `kv_layer_count=3`,
    `rotating_kv_layer_count=12`, and `requires_disk_backed_restore=true`.
    The current model row is
    `osaurusai--gemma-4-e2b-it-qat-jang_4m` with
    `paged_cache.enabled=false` and `block_disk_store.enabled=true` with
    `hits=1`, `misses=1`, and `stores=1`.
  - Earlier repeated-prefix MXFP4 L2 proof:
    `/tmp/osaurus-gemma-proof/cache-after-l2-long-repeat-streamdiag.json`
    reports aggregate `disk_l2_hits=1`, `disk_l2_misses=6`,
    `disk_l2_stores=4`, `paged_hits=0`, and `paged_misses=0`.
    The current model row is `osaurusai--gemma-4-e2b-it-qat-mxfp4` with
    `effective_kv_mode="turbo(3,3)"`, `paged_cache.enabled=false`,
    `block_disk_store.enabled=true`, `block_disk_store.hits=1`, and
    `requires_disk_backed_restore=true`. This is the concrete proof that L2
    disk prefix caching still works with paged RAM cache off.
  - Final e8b5 tool cache telemetry:
    `/tmp/osaurus-gemma-proof/cache-after-tools-e8b5.json` reports MXFP4
    current with `effective_kv_mode="turbo(3,3)"`,
    `paged_cache.enabled=false`, `disk_l2_stores=2`, `paged_hits=0`,
    `paged_misses=0`, `kv_layer_count=3`, `rotating_kv_layer_count=12`, and
    `requires_disk_backed_restore=true`.
  - Short repeated prompts only produced L2 stores/misses with `disk_l2_hits=0`;
    the proven hit row requires a long enough shared prefix to cross the block
    reuse threshold.

## Prefill Progress Contract

- Progress units are prompt-processing work units. For text-only rows this is
  prompt tokens; cache restore counts restored prompt tokens, and prefill counts
  remaining prompt tokens consumed before first decode token.
- Osaurus stages:
  - `queued`: request admitted, total prompt-token count known when available.
  - `cacheLookup`: prefix/L2 lookup is running.
  - `cacheRestore`: cache hit restored prompt tokens from paged/L2/disk tiers.
  - `prefill`: uncached prompt work is running.
  - `complete`: prefill has seeded decode and the first token path can start.
- Calculation:
  `percent = min(100, max(0, completedUnitCount / totalUnitCount * 100))`.
  If `totalUnitCount == 0`, UI must render the stage as indeterminate rather
  than inventing a fake percent.
- Current proven wiring:
  vMLX `Generation.prefillProgress` -> Osaurus `ModelRuntimeEvent` ->
  `StreamingPrefillProgressHint` -> Chat UI `InferenceProgressManager` and
  OpenAI-compatible SSE `osaurus_prefill` chunks.
- Current proven status:
  vMLX BatchEngine emits stage-boundary progress and cache-restore counts, the
  common `LLMModel.prepare` chunk loop reports completed prompt units, VLM
  embedding chunk helpers report completed units, Gemma 4 reports chunked
  prefill progress from its token-plus-embedding prepare path, and the B=1 solo
  fast path now forwards `TokenIterator` prefill progress into the returned
  `Generation` stream. The e8b5 live Osaurus API row proves
  `osaurus_prefill` chunks before first token for a long Gemma QAT prompt.

Open prefill/TTFT work before checkpoint:

- Add or verify a first-class TTFT metric. Token/s is already in final SSE
  usage, but users feel the prefill wait before first token. For the matrix,
  record either engine-emitted TTFT or timestamp-derived TTFT from:
  request start, first `osaurus_prefill`, `complete/decode_ready`, first text
  delta, and final usage.
- Percent calculation must stay honest for every model type:
  - Text-only or text path: denominator is prompt token count after template
    rendering. Completed units are restored cache tokens plus prefilled prompt
    tokens.
  - Gemma VL image path: denominator must include the text tokens plus image
    embedding/prompt units known to the runtime. If exact image units are not
    known, render determinate text-token progress plus a labeled
    indeterminate media-embedding stage rather than faking 100%.
  - Gemma audio path: same rule as VL. If the runtime knows audio feature
    chunks, use them as units; otherwise show an indeterminate audio-embedding
    stage followed by determinate text-token prefill.
  - L2 cache restore: completed units should jump by restored prompt units so
    repeated-prefix rows visibly move faster instead of showing a long blind
    wait.
  - Multi-batch path: each request needs its own progress state keyed by
    request/conversation stream, not one global percent.
- UI must clear progress on first visible delta, cancellation, error, and final
  completion. Stale `Prefill 100%` state after generation is a UI bug.
- API clients get top-level `osaurus_prefill` chunks with empty `choices` so
  OpenAI-compatible stream parsers can ignore them, while Osaurus UI can render
  them. Do not hide progress inside text deltas.
- Final visual proof still needs a screenshot or log-backed UI observation
  during a deliberately slow/long prompt, not only SSE parsing.

## Remaining Proof Gates

## Clean-Main Checkpoint Proof - 2026-06-11 19:05 PT

Branch under test: `codex/gemma-cache-prefill-checkpoint-main`.

vMLX pin under test:
`a4aa133689417b924833610db0ff2732151d74cd`.

Clean-main app build:

- Unsigned Debug app build passed from the workspace:
  `/tmp/osaurus-gemma-proof/xcode-build-debug-app-main-a4aa-rerun1.log`
  ends with `** BUILD SUCCEEDED **`.
- Unsigned Debug app rebuild after restoring QAT-only scope also passed:
  `/tmp/osaurus-gemma-proof/xcode-build-debug-app-main-a4aa-rerun2.log`
  ends with `** BUILD SUCCEEDED **` and resolves `mlx-swift @ a4aa133`.
- Local gitignored unblocker for the build:
  `App/osaurus/Secrets.xcconfig` with empty telemetry/Sentry values. This file
  is intentionally not part of the PR.

Clean-main launch:

- App path:
  `/tmp/osaurus-gemma-checkpoint-main/build/XcodeDerivedData-gemma-main-app/Build/Products/Debug/osaurus.app`.
- Launched with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`,
  `OSAURUS_TEST_ROOT=/tmp/osaurus-keychain-free-gemma-main-a4aa-20260611-190223`,
  `OSU_MODELS_DIR=/Users/eric/models`, and `OSU_PORT=1337`.
- `/health` artifact:
  `/tmp/osaurus-gemma-proof/clean-main-health.json`.
  It reports `status="healthy"`, model root `/Users/eric/models`,
  `model_count=27`, and no loaded model before the smoke rows.
- `/v1/models` artifact:
  `/tmp/osaurus-gemma-proof/clean-main-models.json`.
  It advertises the requested Gemma QAT MXFP4/JANG_4M bundles. Extra local
  folders in the model root are ignored for this checkpoint.
- Runtime defaults artifact:
  `/tmp/osaurus-keychain-free-gemma-main-a4aa-20260611-190223/config/server-runtime.json`.
  It has `cache.pagedKV.enabled=false`, `cache.blockDisk.enabled=true`,
  `cache.legacyDisk.enabled=false`, `cache.prefix.enabled=true`, and
  `cache.liveKVCodec="engine_selected"`.

Clean-main direct tool-call proof:

- E2B MXFP4 forced OpenAI-compatible tool row passed:
  `/tmp/osaurus-gemma-proof/clean-main-chat-e2b-mxfp4-tool-forced.json`.
  It returned `finish_reason="tool_calls"`, tool name `complete`, and exact
  arguments `{"summary":"clean main mxfp4 tool ok"}`.
- E2B MXFP4 tool-result continuation passed:
  `/tmp/osaurus-gemma-proof/clean-main-chat-e2b-mxfp4-tool-continuation.json`.
  It returned visible text and `tokens_per_second=6.9944`.
- E2B JANG_4M forced OpenAI-compatible tool row passed:
  `/tmp/osaurus-gemma-proof/clean-main-chat-e2b-jang4m-tool-forced.json`.
  It returned `finish_reason="tool_calls"`, tool name `complete`, and exact
  arguments `{"summary":"clean main jang4m tool ok"}`.
- E2B JANG_4M tool-result continuation passed:
  `/tmp/osaurus-gemma-proof/clean-main-chat-e2b-jang4m-tool-continuation.json`.
  It returned visible text and `tokens_per_second=8.0922`.

Clean-main prefill/cache proof:

- Long JANG_4M streaming prompt:
  `/tmp/osaurus-gemma-proof/clean-main-chat-e2b-jang4m-prefill-long.sse`.
  It emitted `osaurus_prefill` chunks from `queued` through
  `complete 12622/12622 decode_ready` before the first content token
  `checkpoint`.
- Repeated long JANG_4M prompt:
  `/tmp/osaurus-gemma-proof/clean-main-chat-e2b-jang4m-prefill-long-repeat.sse`.
- Cache after repeated long prompt:
  `/tmp/osaurus-gemma-proof/clean-main-cache-after-prefill-repeat.json`.
  It reports `disk_l2_hits=1`, `block_disk_store.hits=1`,
  `paged_hits=0`, `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
  `turbo_quant_compressions=4`, `kv_layer_count=3`,
  `rotating_kv_layer_count=12`, and `requires_disk_backed_restore=true`.
- RSS sample after the direct tool rows:
  `/tmp/osaurus-gemma-proof/clean-main-ps-after-tools.txt`.
  It records the clean-main app process at about 1.85 GB RSS after the E2B
  tool rows.

Clean-main agent-loop status:

- Built-in default-agent route accepted the clean-main JANG_4M model and
  streamed a response:
  `/tmp/osaurus-gemma-proof/clean-main-agent-run-e2b-jang4m.sse`.
- Status is `PARTIAL`: the route did not emit a tool call for the
  `complete` instruction and answered directly. Direct OpenAI-compatible tool
  calling is proven for MXFP4 and JANG_4M above, but final UI/agent-loop proof
  still needs either a chat UI run or an agent-loop request that actually emits
  and executes a tool call.
- Superseded status update: commit `5a885570` now has forced
  `/agents/{defaultUUID}/run` agent-loop execution proof for 12B JANG_4M and
  12B MXFP4 in the current-tree proof section above. The older clean-main E2B
  row remains useful as the historical failure artifact, not the current
  checkpoint state.

Exact rebuilt-app proof after QAT-only scope correction:

- Discarded artifact warning: live `rerun2` API artifacts were not counted
  because port `1337` was still served by an older Debug app path. The counted
  live proof below uses process `5718` from:
  `/tmp/osaurus-gemma-checkpoint-main/build/XcodeDerivedData-gemma-main-app/Build/Products/Debug/osaurus.app/Contents/MacOS/osaurus`.
- Health artifact:
  `/tmp/osaurus-gemma-proof/health-main-a4aa-rerun3.json`.
  It reports `status="healthy"`, model root `/Users/eric/models`, and no
  loaded model before the rerun3 rows.
- Process/path proof:
  `/tmp/osaurus-gemma-proof/pgrep-before-live-main-a4aa-rerun3.txt`.
- E2B JANG_4M forced OpenAI-compatible tool row passed:
  `/tmp/osaurus-gemma-proof/chat-tool-jang4m-main-a4aa-rerun3.json`.
  It returned `finish_reason="tool_calls"`, tool name `complete`, and exact
  arguments `{"summary":"qat jang4m main a4aa rerun3 tool ok"}`.
- E2B MXFP4 forced OpenAI-compatible tool row passed:
  `/tmp/osaurus-gemma-proof/chat-tool-mxfp4-main-a4aa-rerun3.json`.
  It returned `finish_reason="tool_calls"`, tool name `complete`, and exact
  arguments `{"summary":"qat mxfp4 main a4aa rerun3 tool ok"}`.
- E2B JANG_4M tool-result continuation passed:
  `/tmp/osaurus-gemma-proof/chat-tool-result-jang4m-main-a4aa-rerun3.json`.
  It returned visible text
  `The tool returned the summary: "qat jang4m main a4aa rerun3 tool ok".`
  with `tokens_per_second=18.5051`.
- E2B MXFP4 tool-result continuation passed:
  `/tmp/osaurus-gemma-proof/chat-tool-result-mxfp4-main-a4aa-rerun3.json`.
  It returned visible text
  `The tool returned the summary "qat mxfp4 main a4aa rerun3 tool ok".`
  with `tokens_per_second=17.0711`.
- E2B JANG_4M long-prefix prefill/L2 proof:
  `/tmp/osaurus-gemma-proof/chat-prefill-jang4m-main-a4aa-rerun3-first.sse`,
  `/tmp/osaurus-gemma-proof/chat-prefill-jang4m-main-a4aa-rerun3-repeat.sse`,
  and
  `/tmp/osaurus-gemma-proof/cache-after-prefill-jang4m-main-a4aa-rerun3.json`.
  The stream emitted 26 `osaurus_prefill` chunks per run before the visible
  answer `checkpoint`; cache telemetry reports `effective_kv_mode="turbo(3,3)"`,
  `paged_cache.enabled=false`, `block_disk_store.hits=1`,
  `block_disk_store.stores=2`, and `turbo_quant_compressions=2`.
- E2B MXFP4 long-prefix prefill/L2 proof:
  `/tmp/osaurus-gemma-proof/chat-prefill-mxfp4-main-a4aa-rerun3-first.sse`,
  `/tmp/osaurus-gemma-proof/chat-prefill-mxfp4-main-a4aa-rerun3-repeat.sse`,
  and
  `/tmp/osaurus-gemma-proof/cache-after-prefill-mxfp4-main-a4aa-rerun3.json`.
  The stream emitted 26 `osaurus_prefill` chunks per run before the visible
  answer `checkpoint`; cache telemetry reports `effective_kv_mode="turbo(3,3)"`,
  `paged_cache.enabled=false`, `block_disk_store.hits=1`,
  `block_disk_store.stores=2`, and `turbo_quant_compressions=2`.
- RSS/health after rerun3 E2B live rows:
  `/tmp/osaurus-gemma-proof/ps-after-e2b-live-main-a4aa-rerun3.txt` records
  `RSS=711072 KB`, and
  `/tmp/osaurus-gemma-proof/health-after-e2b-live-main-a4aa-rerun3.json`
  reports current model `osaurusai--gemma-4-e2b-it-qat-mxfp4` with RAM
  verdict `ok`.

- Unblock the required harness suites. This branch can build and test the
  cache/runtime changes, but the documented AgentLoop harness lives on newer
  upstream main alongside a larger OsaurusCore agent-loop stack. Do not mark
  QAT harness scoring complete until the branch contains that complete harness
  implementation and the commands below run successfully.
- Once unblocked, run the required harness suites for each QAT target model:

```sh
swift run --package-path Packages/OsaurusEvals osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/AgentLoopFrontier \
  --model <prefix>/<model-id> \
  --out build/eval-reports/<model>-frontier.json

swift run --package-path Packages/OsaurusEvals osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/AgentLoop \
  --model <prefix>/<model-id> \
  --out build/eval-reports/<model>-agentloop.json
```

- Treat `SandboxFrontier` as an off-CI/extra lane unless the sandbox host and
  entitlement-signed CLI are available.
- Run Chat UI and server/API rows for Gemma MXFP4/JANG_4M with cache telemetry
  proving paged RAM off, disk/L2 on, and TurboQuant KV on where valid.
- Run QAT MXFP4 and JANG_4M harness rows and record scores, token/s, cache
  topology, memory footprint, and multi-turn visible behavior. Improve model
  or runtime behavior only where the harness score/logs show a real failure.
- Token/s is now exposed through OpenAI-compatible SSE usage chunks when
  `stream_options.include_usage=true`. Add normal visible-generation token/s
  rows for every model family before merge-ready wording.
- Prefill progress is wired through vMLX single-batch and scheduler paths,
  Osaurus runtime events, the Chat UI manager, and OpenAI-compatible SSE
  diagnostic chunks. The e8b5 API row proves determinate progress chunks before
  first token; final visual proof still needs a Chat UI observation showing the
  same percentage during a slow/long prompt.
- Final completion gate is app-facing, not source-only:
  - Build the unsigned/dev Osaurus app without keychain/signing prompts.
  - Load a Gemma 4 QAT model from `~/models`.
  - Chat with it and verify coherent visible output.
  - Exercise a real tool call inside Osaurus and verify exact tool
    name/arguments plus tool-result continuation.
  - Capture token/s, cache topology, prefill progress visibility, and RAM /
    physical-footprint observations during load and generation.

## Inventory Status

- `~/models` currently contains the 10 requested QAT MXFP4/JANG_4M repos.
- Only these ten QAT bundles count for this checkpoint.
