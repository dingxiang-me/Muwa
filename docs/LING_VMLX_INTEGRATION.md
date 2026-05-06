# Ling vMLX Integration Notes

Date: 2026-05-06

This PR wires the Osaurus UI/catalog side of Ling-2.6 Flash to the vmlx
BailingHybrid runtime path.

## Dependency Pins

- `vmlx-swift-lm`: `4a832400264e725db384ace4524f2b624b2aefac`
  - BailingHybrid model/factory support for `bailing_moe`,
    `bailing_hybrid`, and `bailing_moe_v2_5`.
  - Bailing/Ling `think_xml` reasoning stamp.
  - Hybrid cache reset/prestacker fixes needed for production loading.
  - Unsupported JANGTQ3 route removed. Ling uses JANGTQ2/JANGTQ4-style
    supported group sizing only.
  - Bailing input processor maps `additionalContext["enable_thinking"]` to
    the upstream template contract: `detailed thinking on/off` in the system
    message before tokenizer rendering. Osaurus always sends `false` for
    Ling-2.6 Flash.
  - Hybrid SSM companion cache state is hardened with the production
    prompt-boundary re-derive gate and disk companion cap.
  - MiniMax JANGTQ_K config decoding now honors nested
    `mxtq_bits.routed_expert` per-projection bits.
  - DSV4 Flash keeps the production SWA+CSA+HSA `DeepseekV4Cache` topology by
    default. Global TurboQuant KV settings no longer replace that hybrid pool;
    `DSV4_KV_MODE=full` / `tq` are diagnostic-only operator overrides.
  - DSV4 L2 disk restore persists the rotating SWA window plus CSA/HSA pool and
    incomplete compressor/indexer buffers under the vmlx `LayerKind.deepseekV4`
    serializer path.
  - Laguna include-only tokenizer bundles render through the native
    Poolside/Laguna fallback template, including reasoning history preservation
    and closed-thinking direct-answer mode.
  - Model-factory fallback diagnostics are quiet by default; set
    `VMLINUX_MODEL_FACTORY_TRACE=1` only when debugging factory dispatch.
  - The vmlx Osaurus runtime handoff notes include the DSV4/Laguna status,
    BatchEngine versus simple TokenIterator speed rows, and reproducible
    `RunBench` commands through the current vmlx `origin/main` pin.
- `swift-jinja`: unchanged at the existing Osaurus fork pin. No new parser
  behavior is needed for Ling in this PR.
- `mlx-swift` / `mlx`: unchanged. No MLX kernel or ABI change is required by
  this osaurus integration.

## Osaurus Wiring

- Adds curated catalog entries for:
  - `OsaurusAI/Ling-2.6-flash-MXFP4`
  - `OsaurusAI/Ling-2.6-flash-JANGTQ`
- Both entries declare `modelType: "bailing_hybrid"` so pre-download metadata
  routes through the correct vmlx factory family.
- Adds a Ling runtime profile with no Thinking toggle. Ling-2.6 Flash is
  treated as a non-reasoning chat model in osaurus, and stale persisted
  `disableThinking=false` preferences are filtered out when the model is
  selected.
- Forces `additionalContext["enable_thinking"] = false` for Ling requests at
  tokenization time, including chat, voice, and API paths that omit UI model
  options. vmlx still owns the Ling/Bailing template-specific translation.
- Marks Bailing/Ling names as known hybrid models so the cache coordinator is
  eagerly set to hybrid for Linear-Attn companion cache handling.

## Review Notes

- No osaurus-side prompt mutation is used. The only Ling-specific runtime
  policy in osaurus is the explicit `enable_thinking=false` context passed to
  vmlx before tokenizer rendering.
- No JANGTQ3 path is introduced; the vmlx pin rejects it.
- Ling has no osaurus-side opt-in path for reasoning. This is intentional:
  the Flash SKU is used as a direct-answer chat model, and reasoning-only
  output can leave voice/chat sessions looking stuck behind the Stop control.
- The MiniMax JANGTQ_K decoder fix is included in the same vmlx pin; osaurus
  does not add MiniMax-specific host logic.
- DSV4 cache mode is not forced by osaurus. Leaving `DSV4_KV_MODE` unset is the
  production path because vmlx now owns the SWA/CSA/HSA hybrid cache. Operators
  can still export the env var for diagnostics before launching osaurus.
- Ling/Bailing cache behavior is not guarded in osaurus. Do not add app-layer
  prefill caps or ArraysCache resets; regressions belong in the vmlx
  BailingHybrid/cache topology.
- Large Ling/Bailing speed and memory tuning remains vmlx-side work. The local
  vmlx rows covered short and medium production prompts, including
  `Ling-2.6-flash-JANGTQ2` multi-turn recall.
- No model download smoke test is included in this repo change. The PR relies on
  focused unit coverage and the vmlx `RunBench` build path.

## Verification

- vmlx: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter BailingThinkingTemplateContextTests`
- vmlx: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release --filter MiniMaxJANGTQConfigTests --no-parallel`
- vmlx: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release --filter 'DeepseekV4ModelSmokeTests|LagunaChatTemplateFallbackTests|BatchQuantizeHookTests|CacheCoordinatorTests' --no-parallel`
- vmlx: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --product RunBench`
- osaurus: focused model catalog/profile/hybrid/batch-adapter tests
- osaurus: SwiftPM resolution points tracked workspace locks at the vmlx pin
  above.
