#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0

pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }

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

SOURCE="$ROOT/Packages/OsaurusCore/Services/ModelRuntime/DistributedRuntimeReadiness.swift"
TESTS="$ROOT/Packages/OsaurusCore/Tests/Service/DistributedRuntimeReadinessTests.swift"
DOC="$ROOT/docs/RDMA_TB5_TENSOR_PARALLEL_OSAURUS_SCAFFOLD_2026_06_10.md"
SPEC="$ROOT/docs/RDMA_TB5_NODE_DISCOVERY_PRODUCT_SPEC_2026_06_10.md"

for file in "$SOURCE" "$TESTS" "$DOC" "$SPEC"; do
  [[ -f "$file" ]] || fail_msg "missing ${file#$ROOT/}"
done

require_text "$SOURCE" 'case thunderboltLoopback' "source classifies Thunderbolt loopbacks"
require_text "$SOURCE" 'case thunderboltDirect' "source classifies direct Thunderbolt links"
require_text "$SOURCE" 'case tailscaleControl' "source marks Tailscale separately"
require_text "$SOURCE" 'Tailscale/control-plane only' "source rejects Tailscale data-plane"
require_text "$SOURCE" 'single_rank_not_tp' "source rejects size-1 TP fallback"
require_text "$SOURCE" 'librdmaLoadable' "source tracks librdma separately"
require_text "$SOURCE" 'jacclAvailable' "source tracks JACCL separately"
require_text "$SOURCE" 'ibvDevicesConfigured' "source tracks IBV device config separately"

require_text "$TESTS" 'tailscale_data_plane_forbidden' "tests cover Tailscale rejection"
require_text "$TESTS" 'single_rank_not_tp' "tests cover size-1 fallback rejection"
require_text "$TESTS" 'jaccl_unavailable' "tests cover JACCL gate"
require_text "$TESTS" 'ibv_devices_missing' "tests cover IBV gate"

require_text "$DOC" 'No UI or Settings panel changes' "doc keeps UI out of this scaffold"
require_text "$DOC" 'No vMLX pin bump in this PR' "doc records no vMLX pin bump"
require_text "$DOC" 'Tailscale remains control-plane/SSH only' "doc records Tailscale boundary"
reject_text "$DOC" 'live-ready' "doc avoids live-ready claim"

require_text "$SPEC" 'Enable node discovery' "spec includes node discovery toggle"
require_text "$SPEC" 'Distributed Inference' "spec includes distributed inference menu"
require_text "$SPEC" 'Scan' "spec includes scan button"
require_text "$SPEC" 'Run checks' "spec includes check button"
require_text "$SPEC" 'Start cluster' "spec includes start button"
require_text "$SPEC" 'Animations should reflect state transitions' "spec covers animations"
require_text "$SPEC" 'Tailscale `100.x`' "spec forbids Tailscale data-plane"
require_text "$SPEC" 'Route check' "spec includes route fallback check"
require_text "$SPEC" 'IBV matrix check' "spec includes IBV fallback check"
require_text "$SPEC" 'Collective smoke' "spec includes collective fallback check"
require_text "$SPEC" 'Runtime proof' "spec includes runtime proof fallback check"
require_text "$SPEC" 'A size-1 fallback never appears as distributed-ready' "spec blocks size-1 false ready"

if [[ "$fail" -ne 0 ]]; then
  echo "RDMA/TB5 distributed scaffold guard failed." >&2
  exit 1
fi

echo "RDMA/TB5 distributed scaffold guard passed."
