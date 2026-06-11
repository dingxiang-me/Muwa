# Gemma 4 Diffusion Engine Plan

Last updated: 2026-06-10

## Scope

This note covers Osaurus wiring for `google/diffusiongemma-26B-A4B-it`.
It is intentionally separate from the regular Gemma 4 JANG/MXFP4 release lane:
regular Gemma 4 remains owned by the active runtime/release PR, while this PR
records the new DiffusionGemma boundary and the handoff contract for the native
block-diffusion engine.

## Current Artifacts

| Item | Value |
| --- | --- |
| Hugging Face repo | `google/diffusiongemma-26B-A4B-it` |
| Hugging Face snapshot | `0f28bc42f588fbd8f71e08102b1c3960298a1358` |
| Local staged bundle | `/Volumes/EricsLLMDrive/hf-stage/gemma4-diffusion/google/diffusiongemma-26B-A4B-it` |
| Download status | 20 files, 11 safetensor shards, about 48 GiB on disk |
| vMLX branch | `codex/gemma4-diffusion-engine` |
| vMLX scaffold SHA | `1eff703cb7fc9a72c69a049bb45a334f50b328f5` |
| Osaurus baseline pin | `c2e8e02101117a64347601f303458ea363b83ee0` |

This Osaurus PR does not repin vMLX. The regular Gemma 4 agent is still moving
the active release pin, so this work stays as diagnostics and wiring notes until
the DiffusionGemma runtime is ready to integrate.

## Model Contract

DiffusionGemma is not a normal autoregressive chat model. The public config
declares:

- outer `model_type`: `diffusion_gemma`
- architecture: `DiffusionGemmaForBlockDiffusion`
- nested text `model_type`: `diffusion_gemma_text`
- `canvas_length`: `256`
- generation defaults: `max_denoising_steps=48`, `t_min=0.4`, `t_max=0.8`,
  `stability_threshold=1`, `confidence_threshold=0.005`
- sampler config: `EntropyBoundSamplerConfig`, `entropy_bound=0.1`
- text stack: 30 layers, hidden size 2816, 16 attention heads, 8 KV heads,
  128 experts with top-8 routing
- media markers: `boi_token_id=255999`, `eoi_token_id=258882`,
  `image_token_id=258880`
- vision config: Gemma 4 vision tower with 280 soft tokens per image

The engine must use a block-diffusion denoising loop over a fixed canvas. It
must not be sent through `BatchEngine`'s existing autoregressive token iterator
as if it were Gemma 4 text.

## Osaurus Behavior For This PR

`ModelCompatibilityDiagnostics` marks DiffusionGemma as blocked with an
explicit runtime diagnostic:

- `model_type=diffusion_gemma`
- `model_type=diffusion_gemma_text`
- architecture `DiffusionGemmaForBlockDiffusion`
- repo names containing `diffusiongemma`

This prevents a complete local bundle from being presented as runnable before
the native vMLX generation path exists. The UI should show the model as a
downloaded but runtime-blocked bundle, matching Hunyuan Dense and LongCat style
diagnostics.

## vMLX Scaffold Status

The current vMLX scaffold at `1eff703c` is source-ready only:

- `FIXED`: DiffusionGemma config decodes the outer config, nested Gemma 4 text
  config, canvas length, media token IDs, and diffusion generation defaults.
- `FIXED`: the model factory has explicit `diffusion_gemma` and
  `diffusion_gemma_text` registrations so the architecture is not aliased to
  regular Gemma 4 autoregressive generation.
- `FIXED`: the scaffold fails closed before autoregressive generation with a
  typed block-diffusion runtime error.
- `PARTIAL`: encoder config and initial weight-prefix mapping are present.
- `BLOCKED`: decoder canvas denoising, self-conditioning, entropy-bound
  sampler, image conditioning, cache reuse, RAM footprint, token/s equivalent,
  and live Osaurus chat/API output are not implemented or proven.

Focused vMLX proof on the scaffold:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DiffusionGemma --jobs 1
```

The last focused test run passed after avoiding Metal-backed model
instantiation in source/config tests.

## Runtime Implementation Checklist

1. Add native block-diffusion generation in vMLX.
2. Keep prompt encoder KV cache separate from decoder canvas state.
3. Implement the denoising scheduler from `generation_config.json`.
4. Preserve bundle defaults; do not invent sampler or reasoning defaults.
5. Add canvas token/state events or final text events that Osaurus can map
   without parser hacks.
6. Add image conditioning only when the Gemma 4 vision tower path is proven
   with a real image payload.
7. Add cache proof: prompt prefix reuse can use KV/L2 evidence, but decoder
   canvas state is not regular per-token KV and needs its own proof boundary.
8. Add cancellation and memory gates before the first unsafe MLX allocation.
9. Add Osaurus integration tests for diagnostic blocked state, then replace the
   block only after live generation proof exists.

## Required Release Proof Before Enabling

No release-ready claim should be made until all of these are green on a pinned
Osaurus app build:

- local load completes without native crash
- visible answer, no random character leakage, no parser marker leakage
- multi-turn coherence
- generation timing is recorded in a form comparable to token/s or denoise
  steps/s
- physical footprint is recorded and within policy or gracefully refused
- prompt-prefix cache and disk L2 behavior are recorded
- image row uses a real image payload if image support is enabled
- cancellation leaves no stuck model lease or orphaned engine state

## Team Wiring Notes

When the native vMLX API is ready, Osaurus should add a feature-gated route
rather than treating DiffusionGemma as another chat-completion family. UI
controls should expose only bundle-backed diffusion settings:

- max denoising steps
- `t_min` / `t_max`
- canvas length, read-only unless the engine proves variants
- entropy bound
- stability and confidence thresholds
- image attachment support only when the media row is proven

Tool calling and reasoning selectors should remain hidden until the model
bundle and runtime expose a real contract for them.
