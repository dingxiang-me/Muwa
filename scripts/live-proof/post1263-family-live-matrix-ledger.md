# Post-1263 production family live matrix ledger

This ledger tracks the follow-on production matrix work after the Gemma reasoning-tool routing PR head.
It is intentionally live-proof oriented: source tests are useful, but a row is not promoted unless the no-sign Osaurus app path proves chat/tool/cache behavior.

## Required proof shape

Each promoted row needs current-head evidence for:

- no-sign Release app path and commit head
- model id from `/v1/models`
- multi-turn chat through `/v1/chat/completions`
- required `line_count` tool call with exact multiline arguments on turn 1
- tool-result follow-up with visible answer and no protocol leak
- second required `line_count` tool call with exact multiline arguments after assistant/tool history
- no raw family protocol leakage in `content` or `reasoning_content`
- token/s recorded for generation turns, or explicitly recorded as unavailable/zero-token tool turn
- `/admin/cache-stats` topology captured for the model
- architecture-specific cache evidence, not generic load success

## Architecture cache requirements

- Full KV models: prefix/L2 disk reuse, and TurboQuant KV only when explicitly enabled and proven for the row.
- Qwen/Ling/Nemotron hybrid SSM/Mamba: KV plus SSM/companion state proof; TurboQuant KV is not a substitute.
- ZAYA/CCA/VL: CCA companion/pooling proof, VL media payload where applicable, and cache salt isolation.
- DSV4: CSA/HSA/SWA hybrid-pool topology plus disk restore/hit proof; TurboQuant KV is not a substitute.
- Gemma rotating/SWA: rotating topology plus disk restore/reuse proof; no Zyphra/Gemma XML leak from reasoning or content.
- HY3/Hunyuan/MiMo-style SWA/CCA paths: run only against an actual local model id and require topology-specific companion or SWA proof.
- MiMo V2.5: expected source topology is 9 full-attention KV layers plus 39 SWA rotating layers. Prefix/L2 disk proof is required; TurboQuant KV is allowed only for full-attention `KVCacheSimple` layers when explicitly enabled and must not replace SWA rotating state.

## Current starting boundary

- Base head at creation: `3b2a4f38fdbc08d5a195cf40689414dc469ab5f2`.
- vMLX pin at creation: `531439a05bb3c5334aa551a07481fc5234644329`.
- Current MiMo-aware vMLX pin staged for this branch: `d69a12168fe6d5c89cb2756ca478f0ea7e18c7d3`.
- `#1263` is still open on GitHub at creation time; this PR is stacked rather than post-merge until GitHub state changes.
- Do not merge by agent.
- Do not apply forced-behavior fixes, hidden sampler overrides, forced thinking/tool wrappers, or broad parser masks to make rows look green.

## Row status ledger

| Row | Status | Artifact | Notes |
| --- | --- | --- | --- |
| Gemma 4 26B JANG_4M | current-head API pass, cache-hit depth partial | `/tmp/osaurus-pr1263-3b2a4f38-gemma4-current-head-proof-20260527-074030/SUMMARY.json` | exact tool args, no protocol leak, disk L2 stores but no hit in short cold proof |
| Nemo Omni MXFP4 | warm pass | `/tmp/osaurus-pr1264-c66a0913-nemotron-mxfp4-warm-20260527-075223/SUMMARY.json` | exact multi-turn `line_count`, no assistant-header/protocol leak, `disk_l2_hits +3`, `ssm_companion_hits +3`, 29 layers with 6 KV + 23 Mamba, TurboQuant KV 0 |
| Nemo Omni JANGTQ | warm pass | `/tmp/osaurus-pr1264-c66a0913-nemotron-jangtq-warm-20260527-075247/SUMMARY.json` | exact multi-turn `line_count`, no assistant-header/protocol leak, `disk_l2_hits +3`, `ssm_companion_hits +3`, 29 layers with 6 KV + 23 Mamba, TurboQuant KV 0 |
| Nemo Omni JANGTQ4 | warm pass | `/tmp/osaurus-pr1264-c66a0913-nemotron-jangtq4-warm-20260527-075313/SUMMARY.json` | exact multi-turn `line_count`, no assistant-header/protocol leak, `disk_l2_hits +3`, `ssm_companion_hits +3`, 29 layers with 6 KV + 23 Mamba, TurboQuant KV 0 |
| Ling JANGTQ2 | pass | `/tmp/osaurus-pr1264-009688d3-ling-jangtq2-20260527-075413/SUMMARY.json` | exact multi-turn `line_count`, no protocol leak, `disk_l2_hits +1`, `ssm_companion_hits +1`, 32 layers with 4 KV + 28 arrays/SSM, TurboQuant KV 0 |
| Ling MXFP4 | pass | `/tmp/osaurus-pr1264-009688d3-ling-mxfp4-20260527-075431/SUMMARY.json` | exact multi-turn `line_count`, no protocol leak, `disk_l2_hits +1`, `ssm_companion_hits +1`, 32 layers with 4 KV + 28 arrays/SSM, TurboQuant KV 0 |
| ZAYA text/VL | pending | | VL must use real media payload before promotion |
| DSV4 JANGTQ2 | warm pass | `/tmp/osaurus-pr1264-c2108825-dsv4-jangtq2-warm-20260527-075623/SUMMARY.json` | exact multi-turn `line_count`, no DSML/protocol leak, 43 layers with 41 hybrid-pool/rotating-wrapper + 2 rotating KV, `disk_l2_hits +1`, TurboQuant KV 0 |
| DSV4 JANGTQ-K | warm pass | `/tmp/osaurus-pr1264-c2108825-dsv4-jangtq-k-warm-20260527-075727/SUMMARY.json` | exact multi-turn `line_count`, no DSML/protocol leak, 43 layers with 41 hybrid-pool/rotating-wrapper + 2 rotating KV, `disk_l2_hits +1`, TurboQuant KV 0 |
| Qwen 27B MXFP4 MTP | warm pass | cold fixed-behavior row `/tmp/osaurus-pr1264-42c8ae95-qwen27-mxfp4-mtp-20260527-083311/qwen27-mxfp4-mtp/qwen3.6-27b-mxfp4-crack-mtp_summary.json`; warm proof `/tmp/osaurus-pr1264-42c8ae95-qwen27-mxfp4-mtp-warm-20260527-083324/qwen27-mxfp4-mtp/qwen3.6-27b-mxfp4-crack-mtp_summary.json`; prior red repro `/tmp/osaurus-pr1264-current-qwen27-repro-20260527-080759` | `42c8ae95` with vMLX `54bbf805c756b28f12136f24b6794f87069136e7` fixes the reasoning-only length-stop after tool history: turn2 visible `3 lines were counted.`, stop finish, no protocol leak, turn1/turn3 exact `line_count` tool calls. Cold row stored L2 (`disk_l2_stores +4`) but had no hits; immediate warm row passed with `disk_l2_hits +3`, `ssm_companion_hits +3`, 64 layers with 16 KV + 48 Mamba, TurboQuant KV 0 |
| Qwen 35B variants | pending | | must cover SSM companion/cache and generation_config defaults after Qwen 27B warm-cache red row is understood |
| MiniMax M2.7 Small JANGTQ | pending | | local bundle exists at `/Users/eric/models/JANGQ/MiniMax-M2.7-Small-JANGTQ`; matrix row now requires XML tool parser, reasoning rail separation, prefix/L2 disk reuse, and no compiled-decode fallback |
| MiniMax M2.7 JANGTQ_K / JANG_K | pending | | local sibling bundles exist under `/Users/eric/models/dealign.ai`; matrix row for JANGTQ_K is present; run only with memory budget |
| MiMo V2.5 | source/vMLX guard pass, live blocked | `/Users/eric/jang`: `uv run --project jang-tools pytest -q jang-tools/tests/mimo_v2_contract_test.py`; vMLX `d69a12168fe6d5c89cb2756ca478f0ea7e18c7d3` | JANG source contract passed; vMLX guard pins `mimo_v2_flash` topology as 9 full-attention `KVCacheSimple` layers plus 39 SWA `RotatingKVCache` layers, with TurboQuant KV limited to full-attention KV layers only. No converted/imported Osaurus model bundle found, so live Osaurus cache/tool row is blocked until a bundle exists |
| HY3/Hunyuan/MiMo local rows | pending | | run only if actual local model id exists |
