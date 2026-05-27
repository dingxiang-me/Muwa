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

## Current starting boundary

- Base head at creation: `3b2a4f38fdbc08d5a195cf40689414dc469ab5f2`.
- vMLX pin at creation: `531439a05bb3c5334aa551a07481fc5234644329`.
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
| Ling variants | pending | | must cover JANGTQ2 and MXFP4 hybrid companion/cache proof |
| ZAYA text/VL | pending | | VL must use real media payload before promotion |
| DSV4 variants | pending | | must cover JANGTQ2 and sibling rows with hybrid-pool cache proof |
| Qwen 27B/35B variants | pending | | must cover SSM companion/cache and generation_config defaults |
| HY3/Hunyuan/MiMo local rows | pending | | run only if actual local model id exists |
