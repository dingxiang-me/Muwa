# Production release readiness - vmlx-swift-lm pin and DSV4 runtime path

This checklist defines what can be claimed for the current Osaurus runtime PR
and what remains outside the release claim. It is intentionally public-safe:
no local model paths, private notes, secrets, or host-specific state are needed
to evaluate the claim.

## Claim boundary

Claimable for this PR:

- Osaurus is pinned to the required Osaurus-owned `vmlx-swift-lm`,
  `mlx-swift`, `Jinja`, and `swift-transformers` revisions.
- The local MLX path preserves bundle generation defaults when chat does not
  explicitly set max tokens.
- DSV4 local reasoning controls route through the canonical vmlx encoder:
  `instruct` closes thinking, `high` opens the high-reasoning rail, and `max`
  preserves the raw max preface without secretly downgrading it.
- DSV4 DSML tool schemas reach the canonical template path and DSML tool-call
  bytes are routed away from visible text.
- Reasoning bytes and visible bytes stay separated by vmlx parser events and
  Osaurus streaming hints; interleaved thinking tags are not app-parsed as
  user-visible text.
- Cache claims are topology-specific. DSV4 stays on the vmlx-owned
  `DeepseekV4Cache` composite path; Osaurus does not force generic TurboQuant
  KV for DSV4.
- Memory, skills, tool-selection, and context-budget plumbing are covered by
  the Osaurus context/test matrix.

Not claimable from this PR:

- Raw DSV4 `reasoning_effort=max` long-context quality is not release-ready.
  The diagnostic test remains disabled until repeated real-model runs stop
  cleanly without thinking-loop, length-stop, or malformed-tail degeneration.
- A live DSV4 tool smoke that produces prose instead of a tool invocation does
  not prove the local model will always call tools. It proves the request path
  accepts tools without unsupported-tool failure; schema injection and DSML
  parser behavior are proven by focused tests.
- This PR does not clear every non-DSV4 model family for production quality.
  It clears the touched Osaurus/vmlx integration surfaces and preserves the
  topology-specific validation boundary for future family gates.

## Required function and variable surfaces

| Area | Functions / variables that must stay aligned | Release check |
|---|---|---|
| Runtime pins | `Packages/OsaurusCore/Package.swift`; `Package.resolved` in `Packages/OsaurusCore`, `App/osaurus.xcodeproj`, and `osaurus.xcworkspace` | `scripts/ci/check-runtime-pins.sh` must pass. |
| Default max tokens | `ChatConfiguration.maxTokens`; `ChatConfiguration.default`; `AppConfiguration.clearLegacyDefaultChatMaxTokens(_:)`; `ChatView.effectiveMaxTokensForAgent`; `GenerationParameters.maxTokensExplicit`; `MLXBatchAdapter.effectiveGenerationSettings(...)`; `RemoteProviderService.buildChatRequest(...)` | Nil chat max tokens must omit remote max-token keys and let local bundle defaults win. Explicit user caps must still win. |
| DSV4 local reasoning | `DSV4ReasoningProfile.matches(modelId:)`; `DSV4ReasoningProfile.normalizedEffort(_:)`; `MLXBatchAdapter.additionalContext(for:modelName:)`; `MLXBatchAdapter.isDirectRailReasoningEffort(_:)`; context keys `enable_thinking` and `reasoning_effort` | `instruct` -> `enable_thinking=false`; `high` -> `enable_thinking=true`, `reasoning_effort=high`; `max` -> `enable_thinking=true`, `reasoning_effort=max`. No hidden high fallback. |
| Remote DeepSeek reasoning | `RemoteProviderService.dsv4RemoteEffort(host:model:effort:)`; `RemoteProviderService.remoteChatReasoningControls(...)`; `RemoteProviderService.chatCompletionsReasoningEffort(...)`; `ThinkingConfig(type:)` | `instruct` and off aliases are stripped from `reasoning_effort`; DeepSeek DSV4 gets `thinking: disabled`; `high/max/low/medium/xhigh` pass only when provider accepts them. |
| Template route | `SwiftTransformersTokenizerLoader.load(from:)`; tokenizer `applyChatTemplate(messages:tools:additionalContext:)`; `Tool.toTokenizerToolSpec()` | DSV4 bundles with no tokenizer chat template must use vmlx canonical DSV4 encoding, not generic ChatML or generic tool dialects. |
| Tool parser | `ReasoningParser.forPrompt(stampName:promptTail:)`; `ToolCallProcessor(format: .dsml)`; `routeGenerationText(...)`; `drainToolCallEvents(...)`; `GenerationEventMapper` | DSML invoke blocks become `.toolCall`; DSML markup must not appear in visible chunks. |
| Reasoning stream | vmlx `Generation.reasoning` / `Generation.chunk`; `StreamingReasoningHint`; `StreamingToolHint`; `ChatView` Think panel handling; `GenerationEventMapper` | Reasoning content is routed to reasoning surfaces before generic sentinel filtering. Visible output must not leak `<think>` or DSML markers. |
| Cache topology | `ModelRuntime.installCacheCoordinator`; `ModelRuntime.buildCacheCoordinatorConfig`; vmlx `CacheCoordinator`; vmlx `DeepseekV4Cache`; vmlx `LayerKind.deepseekV4`; Osaurus non-use of `DSV4_KV_MODE` | DSV4 cache status is native composite, not generic TQ-KV. Cache salt includes reasoning/media where relevant. |
| Batch lifecycle | `MLXBatchAdapter.Registry.engine(...)`; `TaskCoalescer`; `BatchEngine.updateMaxBatchSize(_:)`; `SoloGenerationGate`; `ModelLease` | One engine per model, hot resize when valid, evict/rebuild on shutdown, solo gate holds until upstream stream finishes. |
| Audio and VL preservation | `MLXBatchAdapter.preprocessImages(in:)`; `preencodeAudioSources(in:encode:)`; `preencodeNemotronOmniAudioIfPossible(...)`; `preencodedAudio(_:using:)`; `UserInput.Audio.preEncoded` | Image/video/audio arrays, reasoning content, tool calls, and tool-call ids survive preprocessing; omni audio preencode is full-snapshot, not chunk concatenation. |
| Memory and skills context | `MemorySearchService`; `SearchMemoryTool`; `SkillSearchService`; `PreflightCapabilitySearch`; `PreflightCompanions`; `SystemPromptComposer`; `ContextBudgetPreview`; `SessionToolStateStore` | Context/tool/skill selection must stay deterministic, deduped, and bounded by model context class. |

## Required checks

Run these before calling the PR production-release ready:

```sh
scripts/ci/check-runtime-pins.sh

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift build --package-path Packages/OsaurusCore --target OsaurusCore

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path Packages/OsaurusCore

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path Packages/OsaurusCore/.build/checkouts/vmlx-swift-lm \
  --filter 'DeepseekV4ChatTemplateFallbackTests|DeepseekV4ChatEncoderTests|DSMLToolCallParserTests|CacheCoordinatorModeKeyIsolationTests|DeepseekV4CacheDiskRoundTripTests|CacheCoordinatorPagedIncompatibleHybridTests|LLMCacheScopeSourceCoverageTests|VLMCacheScopeSourceCoverageTests|VLMProcessorCacheScopeSaltTests|Hy3ParserDispatchTests|ZayaParserDispatchTests|ReasoningParserTests'
```

Live DSV4 checks are opt-in because they require a local model bundle:

```sh
OSU_MODELS_DIR=<model-root> \
OSAURUS_DSV4_LIVE_SMOKE=1 \
OSAURUS_DSV4_LIVE_MODEL=deepseek-v4-flash-jangtq-k \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path Packages/OsaurusCore \
  --filter 'DSV4FlashLiveSmokeTests/fourTurnAIMEChatSurvivesHighReasoningRail|DSV4FlashLiveSmokeTests/toolPromptReachesLiveDSV4Stream'
```

Required GitHub checks:

- `test-core`: success.
- `test-cli`: success.
- `swiftlint`: success.
- `shellcheck`: success.
- `update_release_draft`: success.
- PR merge state: `CLEAN`.

## Current proof for PR 1110

- Final merge readiness must be verified against the current PR head with
  GitHub checks after the last commit is pushed.
- Before this checklist commit, GitHub status was all required checks passed
  and merge state was `CLEAN`.
- Local Osaurus full suite: `2129 tests in 278 suites` passed.
- Local pinned `vmlx-swift-lm` parser/cache/template suite:
  `128 tests in 13 suites` passed.
- Local memory/skills/context/tooling subset: `147 tests in 13 suites` passed.
- Live high-reasoning DSV4 smoke: four turns passed with clean `stop` reasons,
  expected answers, positive token/s, and no unclosed reasoning.
- Live DSV4 tool prompt smoke: reached terminal stats without unsupported-tool
  failure; tokenizer and parser tests cover schema injection and DSML parsing.

## Release wording allowed

Allowed:

> This release branch is production-ready for the Osaurus runtime integration
> surfaces touched by PR 1110: dependency pins, DSV4 high-reasoning rail,
> DSML parser/template transport, default generation-config handling, cache
> topology ownership, memory/skills context plumbing, and no-leak reasoning
> separation are covered by local tests, live smokes, and green GitHub CI.

Not allowed:

> DSV4 raw max long context is fully production-ready.

> All local model families are release-cleared.

> Tool calling is guaranteed from every DSV4 prompt.

Those require the wider live model production matrix and the raw-max diagnostic
to pass as release gates.
