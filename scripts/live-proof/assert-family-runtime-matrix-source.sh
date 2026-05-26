#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0

pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }

require_file() {
  local file="$1" label="$2"
  if [[ -f "$file" ]]; then
    pass "$label exists"
  else
    fail_msg "missing $label: ${file#$ROOT/}"
  fi
}

require_text() {
  local file="$1" pattern="$2" label="$3"
  if rg -U -q "$pattern" "$file"; then
    pass "$label"
  else
    fail_msg "missing $label in ${file#$ROOT/}"
  fi
}

reject_text() {
  local file="$1" pattern="$2" label="$3"
  if rg -U -n "$pattern" "$file"; then
    fail_msg "forbidden $label in ${file#$ROOT/}"
  else
    pass "no $label"
  fi
}

FAMILY="$ROOT/Packages/OsaurusCore/Models/Configuration/ModelFamilyNames.swift"
OPTIONS="$ROOT/Packages/OsaurusCore/Models/Configuration/ModelOptions.swift"
MEDIA="$ROOT/Packages/OsaurusCore/Models/Configuration/ModelMediaCapabilities.swift"
RUNTIME="$ROOT/Packages/OsaurusCore/Services/ModelRuntime.swift"
ADAPTER="$ROOT/Packages/OsaurusCore/Services/ModelRuntime/MLXBatchAdapter.swift"
TOKENIZER="$ROOT/Packages/OsaurusCore/Services/ModelRuntime/SwiftTransformersTokenizerLoader.swift"
HTTP="$ROOT/Packages/OsaurusCore/Networking/HTTPHandler.swift"
SERVER_SETTINGS="$ROOT/Packages/OsaurusCore/Models/Configuration/ServerRuntimeSettingsStore.swift"
TOOL_TESTS="$ROOT/Packages/OsaurusCore/Tests/Service/MLXBatchAdapterTests.swift"
POLICY_TESTS="$ROOT/Packages/OsaurusCore/Tests/Service/RuntimePolicySourceTests.swift"
DOC="$ROOT/docs/FAMILY_RUNTIME_MATRIX.md"

for pair in \
  "$FAMILY:ModelFamilyNames" \
  "$OPTIONS:ModelOptions" \
  "$MEDIA:ModelMediaCapabilities" \
  "$RUNTIME:ModelRuntime" \
  "$ADAPTER:MLXBatchAdapter" \
  "$TOKENIZER:SwiftTransformersTokenizerLoader" \
  "$HTTP:HTTPHandler" \
  "$SERVER_SETTINGS:ServerRuntimeSettingsStore" \
  "$TOOL_TESTS:MLXBatchAdapterTests" \
  "$POLICY_TESTS:RuntimePolicySourceTests" \
  "$DOC:family runtime matrix doc"; do
  require_file "${pair%%:*}" "${pair#*:}"
done

echo "--- family detection and runtime profiles ---"
require_text "$FAMILY" 'isNemotronOmniFamily' "Nemotron Omni family matcher"
require_text "$FAMILY" 'isLingFamily' "Ling family matcher"
require_text "$FAMILY" 'isZayaFamily' "ZAYA family matcher"
require_text "$FAMILY" 'isZayaVLFamily' "ZAYA VL family matcher"
require_text "$OPTIONS" 'struct NemotronThinkingProfile' "Nemotron thinking profile"
require_text "$OPTIONS" 'struct Hy3ReasoningProfile' "HY3 reasoning-effort profile"
require_text "$OPTIONS" 'struct LingRuntimeProfile' "Ling runtime profile"
require_text "$OPTIONS" 'struct ZayaThinkingProfile' "ZAYA thinking profile"
require_text "$MEDIA" 'ModelFamilyNames\.isNemotronOmniFamily' "Nemotron media capability detection"
require_text "$MEDIA" 'ModelFamilyNames\.isZayaVLFamily' "ZAYA VL image capability detection"

echo "--- local template/tool-choice wiring ---"
require_text "$ADAPTER" 'toolChoice: ToolChoiceOption\? = nil' "additionalContext accepts tool_choice"
require_text "$ADAPTER" 'context\["tool_choice"\] = "required"' "required tool_choice reaches template context"
require_text "$ADAPTER" 'case \.required, \.function\(_\)' "named tool_choice maps to required local call"
require_text "$RUNTIME" 'toolChoice: toolChoice' "ModelRuntime passes tool_choice into MLXBatchAdapter"
require_text "$TOKENIZER" 'toolChoiceRequired' "tokenizer fallback observes required tool_choice"
require_text "$ADAPTER" 'Hy3ReasoningProfile\.matches' "Osaurus maps HY3 to reasoning_effort context"
require_text "$ADAPTER" 'context\["reasoning_effort"\] = Hy3ReasoningProfile\.normalizedEffort' \
  "HY3 context preserves native reasoning_effort instead of generic enable_thinking"
require_text "$TOKENIZER" 'NemotronMinimal' "Nemotron fallback remains wired"

echo "--- topology-aware cache surfaces ---"
require_text "$RUNTIME" 'layers=hybrid-ssm' "hybrid SSM cache key tag"
require_text "$RUNTIME" 'layers=zayaCCA' "ZAYA CCA cache key tag"
require_text "$RUNTIME" 'media=omni-audio-video' "Nemotron Omni media cache key tag"
require_text "$RUNTIME" 'requiresSSMCompanionState' "runtime observes SSM/CCA companion topology"
require_text "$HTTP" 'ssm_companion_cache' "cache stats exposes SSM companion cache"
require_text "$HTTP" 'zaya_cca_layer_count' "cache stats exposes ZAYA CCA layer count"
require_text "$HTTP" 'turbo_quant_kv_layer_count' "cache stats exposes TurboQuant KV layer count"
require_text "$HTTP" 'requires_disk_backed_restore' "cache stats exposes disk-backed restore requirement"

echo "--- TurboQuant remains opt-in until live matrix proves it ---"
require_text "$SERVER_SETTINGS" 'liveKVCodec: \.native' "default live KV codec stays native/fp16"
reject_text "$SERVER_SETTINGS" 'normalized\.cache\.liveKVCodec = \.engineSelected' \
  "legacy migration silently enabling engine-selected TurboQuant KV"
require_text "$DOC" 'TurboQuant KV remains opt-in' "matrix doc records TurboQuant opt-in policy"

echo "--- regression tests cover the source contracts ---"
require_text "$TOOL_TESTS" 'additionalContext_threadsRequiredToolChoiceToLocalTemplates' \
  "tool_choice template-context regression test"
require_text "$TOOL_TESTS" 'additionalContext_defaultsLingThinkingOffButHonorsExplicitOptIn' \
  "Ling thinking-context regression test"
require_text "$TOOL_TESTS" 'additionalContext_mapsReasoningEffortToTemplateKwarg' \
  "HY3 reasoning-effort regression test"
require_text "$TOOL_TESTS" 'additionalContext_normalizesHy3ReasoningEffortAliases' \
  "HY3 reasoning-effort alias regression test"
require_text "$POLICY_TESTS" 'localDecodeLoopKeepsToolSchemasForParserValidation' \
  "local decode loop tool-schema source guard"
require_text "$POLICY_TESTS" 'Runtime Tools' "settings runtime tool visibility guard"

if [[ "$fail" -ne 0 ]]; then
  echo "Family runtime matrix source guard failed." >&2
  exit 1
fi

echo "Family runtime matrix source guard passed."
