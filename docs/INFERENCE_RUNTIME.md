# Inference runtime

osaurus's MLX inference path is a thin shell around vmlx-swift-lm's
`BatchEngine`. Tool-call parsing, reasoning extraction, KV cache
management, and per-model scheduling all live inside the library. This
document describes the small slice osaurus owns.

## End-to-end shape

```
ChatEngine (route resolution, attribution, logging)
    -> ModelRuntime (container lifecycle, model lease, prefill progress)
        -> MLXBatchAdapter
            -> BatchEngine.generate(input:parameters:)
                -> AsyncStream<Generation>
            -> GenerationEventMapper (Generation -> ModelRuntimeEvent)
                -> AsyncThrowingStream<ModelRuntimeEvent, Error>
```

`BatchEngine.generate` returns these event cases:

- `.chunk(String)` -- pure user-visible text. Reasoning markers and
  tool-call markers are stripped by the library before they reach
  osaurus.
- `.reasoning(String)` -- model reasoning text. Osaurus forwards this to
  `ModelRuntimeEvent.reasoning`, HTTP `reasoning_content`, the ChatView
  Think panel, and plugin `chunk.delta.reasoning_content`.
- `.toolCall(ToolCall)` -- a fully-parsed tool call. Every supported
  family (JSON, Qwen `xml_function`, Mistral, GLM-4, LFM2, Kimi K2,
  Gemma-3/4, MiniMax M2) emits this once the call is complete.
- `.info(GenerateCompletionInfo)` -- final stats (token counts, prompt
  / generation time, stop reason, and `unclosedReasoning`). One per request.

`GenerationEventMapper` translates those into osaurus's local
`ModelRuntimeEvent` (`.tokens`, `.reasoning`, `.toolInvocation`,
`.completionInfo`).

## Cache management

vmlx's `CacheCoordinator` owns KV cache geometry. osaurus configures it
per container at load time with three minimal overrides
(`installCacheCoordinator` in [`ModelRuntime.swift`](../Packages/OsaurusCore/Services/ModelRuntime.swift)):

| Override | Why |
|---|---|
| `modelKey` | per-model isolation across loads |
| `diskCacheDir` | osaurus-managed sandbox path |
| `enableDiskCache=false` when dir is unwritable | graceful fallback to memory-only |

Everything else (`maxCacheBlocks`, `pagedBlockSize`, `diskCacheMaxGB`,
`ssmMaxEntries`) is left at the library default so vmlx can ship a
single tuned answer per release.

DSV4 is intentionally left to vmlx's default cache topology. Osaurus does
not set `DSV4_KV_MODE`; unset means the production SWA+CSA+HSA
`DeepseekV4Cache` path. Operator-provided `DSV4_KV_MODE=full` or `tq`
is treated as a diagnostic override and disables the hybrid pool.

osaurus deliberately does not pass `GenerateParameters.maxKVSize` -- a
global rotating cache window forced from the app layer conflicted with
sliding-window attention layers (e.g. Gemma-4 with a fixed per-layer
1024-position window) and produced
`[broadcast_shapes] (1,1,1,N) and (1,16,1,1024)` crashes on the first
decode step.

For hybrid SSM families, osaurus eagerly calls `CacheCoordinator.setHybrid(_:)`
for known model families and vmlx also auto-detects Mamba/Arrays caches on
first slot admission. DSV4 is not an SSM hybrid; vmlx detects its
`HybridPoolCache` and flips `isPagedIncompatible` so prefix reuse goes through
the `LayerKind.deepseekV4` disk serializer instead of generic paged KV blocks.

## Concurrency

| Layer | What it protects |
|---|---|
| `BatchEngine` actor (vmlx) | Serializes Metal / model access. Continuous batching for same-model concurrent requests. |
| `ModelLease` | Pins a model name for the lifetime of one stream so eviction (`unload`, `clearAll`, GC) blocks until the lease drops to zero. |
| `PluginHostAPI` per-plugin in-flight cap | Caps concurrent inference calls per plugin (default 2). Excess returns `plugin_busy`. |
| `MetalGate.enterEmbedding` | Embedding service (`MetalSafeEmbedder`) opt-in serialization point. The generation surface of the gate was retired; only embeddings call into it today. |

## Tunable

A single `defaults` knob remains:

```bash
defaults write ai.osaurus ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize -int 8
```

Defaults to `4`, clamped to `[1, 32]`. Higher values raise total
throughput at the cost of wired-memory footprint and per-request
latency. See [`InferenceFeatureFlags.swift`](../Packages/OsaurusCore/Services/ModelRuntime/InferenceFeatureFlags.swift).

## Sentinel scheme (in-band streaming hints)

`ChatEngine.streamWithTools` returns `AsyncThrowingStream<String,
Error>`. Non-content events ride along on the same stream as sentinel
strings starting with `\u{FFFE}`:

| Sentinel | Producer | Consumer |
|---|---|---|
| `\u{FFFE}tool:` | local + remote tool call name | HTTP SSE -> `tool_calls` deltas; ChatView Think panel |
| `\u{FFFE}args:` | tool argument fragments | HTTP SSE -> `tool_calls.function.arguments` deltas |
| `\u{FFFE}done:` | server-side tool call result | ChatView (tool result card) |
| `\u{FFFE}stats:` | post-stream perf | ChatView, plugin `chunk.delta.stats` |
| `\u{FFFE}reasoning:` | local (forward-compat) + remote `reasoning_content` | OpenAI SSE `reasoning_content`; Anthropic `thinking_delta`; OpenResponses `response.reasoning_summary_text.delta`; ChatView Think panel; plugin `chunk.delta.reasoning_content` |

HTTP handlers and the plugin SDK MUST decode `StreamingReasoningHint`
BEFORE the generic `StreamingToolHint.isSentinel` filter, otherwise
reasoning gets dropped together with the other sentinels.

## Source map

| File | Role |
|---|---|
| `ModelRuntime.swift` | Container lifecycle (load / unload / strict eviction), `ModelLease` glue, single MLX entry into `MLXBatchAdapter`. |
| `MLXBatchAdapter.swift` | Per-model `BatchEngine` registry; submits each request via `engine.generate(...)`. |
| `GenerationEventMapper.swift` | `Generation` -> `ModelRuntimeEvent` bridge; stop-sequence lookahead; tool-call argument JSON serialization. |
| `Events.swift` | `ModelRuntimeEvent` enum (`tokens` / `reasoning` / `toolInvocation` / `completionInfo`). |
| `RuntimeConfig.swift` | Server-side default `topP`. |
| `InferenceFeatureFlags.swift` | Single user-tunable: `mlxBatchEngineMaxBatchSize`. |
| `MetalGate.swift` | Embedding-only counter (kept as the canonical hook for any future MLX-vs-CoreML interlock). |
| `ModelLease.swift` | Per-model refcount; `unload(name)` waits for `count == 0` before freeing buffers. |

## Tests

| File | Coverage |
|---|---|
| `MLXBatchAdapterTests` | Max-batch-size flag clamping; registry-shutdown safety. |
| `GenerationEventMapperTests` | `chunk` -> `tokens`; `toolCall` -> `toolInvocation` JSON serialization (happy path + failure envelope); `info` -> `completionInfo`; cross-chunk stop-sequence cut. |
| `StreamingReasoningHintTests` | Sentinel encode/decode round-trip; co-existence with the tool sentinel filter. |
| `MetalGateTests` | Embedding gate happy paths. |
