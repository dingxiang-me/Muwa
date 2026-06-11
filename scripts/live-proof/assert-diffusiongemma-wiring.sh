#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

require_text() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if rg -Fq "$needle" "$file"; then
    printf 'PASS %s\n' "$label"
  else
    printf 'FAIL %s\n  missing %s in %s\n' "$label" "$needle" "$file" >&2
    exit 1
  fi
}

DIAG="$ROOT/Packages/OsaurusCore/Services/ModelCompatibilityDiagnostics.swift"
TEST="$ROOT/Packages/OsaurusCore/Tests/Service/ModelCompatibilityDiagnosticsTests.swift"
DOC="$ROOT/docs/GEMMA4_DIFFUSION_ENGINE_PLAN_2026_06_10.md"

require_text "$DIAG" "unsupportedDiffusionGemma" "diagnostic reason code"
require_text "$DIAG" "diffusion_gemma" "outer model type blocked"
require_text "$DIAG" "diffusion_gemma_text" "text model type blocked"
require_text "$DIAG" "diffusiongemmaforblockdiffusion" "architecture blocked"
require_text "$DIAG" "block-diffusion denoising" "diagnostic explains non-AR engine"
require_text "$TEST" "diffusionGemmaConfig_reportsBlockDiffusionRuntimeBoundary" "focused compatibility test"
require_text "$DOC" "1eff703cb7fc9a72c69a049bb45a334f50b328f5" "vMLX scaffold SHA documented"
require_text "$DOC" "This Osaurus PR does not repin vMLX" "regular Gemma lane protected"
require_text "$DOC" "BLOCKED" "unproven runtime rows marked blocked"

printf 'DiffusionGemma Osaurus wiring guard passed.\n'
