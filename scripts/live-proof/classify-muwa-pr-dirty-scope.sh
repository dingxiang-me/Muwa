#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-/tmp/osaurus-pr-dirty-scope-classifier-$(date +%Y%m%d-%H%M%S).md}"
mkdir -p "$(dirname "$OUT")"

all_dirty="$({
  git -C "$ROOT" diff --name-only
  git -C "$ROOT" diff --cached --name-only
  git -C "$ROOT" ls-files --others --exclude-standard
} | sort -u)"

classify() {
  local path="$1"
  case "$path" in
    scripts/live-proof/assert-*.sh|scripts/live-proof/launch-keychain-free-muwa.sh|scripts/live-proof/classify-muwa-pr-dirty-scope.sh)
      echo "release-guard" ;;
    Packages/MuwaCore/Package.swift|Packages/MuwaCore/Package.resolved|Muwa.xcworkspace/xcshareddata/swiftpm/Package.resolved|App/Muwa.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
      echo "dependency-pin" ;;
    .agents/vmlx-osaurus/codex/*)
      echo "coordination-doc" ;;
    Packages/MuwaCore/Services/ModelRuntime/*|Packages/MuwaCore/Services/ModelRuntime.swift|Packages/MuwaCore/Models/Configuration/ServerRuntimeSettingsStore.swift|Packages/MuwaCore/Models/Configuration/ModelOptions.swift|Packages/MuwaCore/Views/Settings/ServerSettings/*|Packages/MuwaCore/Views/Settings/ServerSettingsView.swift)
      echo "runtime-settings-cache" ;;
    Packages/MuwaCore/Networking/*|Packages/MuwaCore/Models/API/*)
      echo "api-streaming-responses" ;;
    Packages/MuwaCore/Services/Chat/*|Packages/MuwaCore/Views/Chat/*)
      echo "chat-reasoning-tool-ui" ;;
    Packages/MuwaCore/Services/Keychain/*|Packages/MuwaCore/Services/MCP/MCPProviderKeychain.swift|Packages/MuwaCore/Identity/StorageKeyManager.swift|Packages/MuwaCore/AppDelegate.swift|AGENTS.md)
      echo "keychain-launch-safety" ;;
    Packages/MuwaCore/Managers/Model/*|Packages/MuwaCore/Services/HuggingFaceService.swift|Packages/MuwaCore/Services/Provider/*|Packages/MuwaCore/Services/Inference/*|Packages/MuwaCore/Services/LocalGenerationDefaults.swift|Packages/MuwaCore/Services/LocalReasoningCapability.swift|Packages/MuwaCore/Services/ModelOptionsStore.swift|Packages/MuwaCore/Services/Context/*|Packages/MuwaCore/Utils/MuwaPaths.swift)
      echo "model-provider-defaults" ;;
    Packages/MuwaCore/Tests/*)
      echo "tests" ;;
    docs/*)
      echo "docs" ;;
    .spm-cache/*|.claude/*|investigation/*|DerivedData*|*.xcresult|*.log)
      echo "local-artifact" ;;
    *)
      echo "unknown" ;;
  esac
}

{
  echo "# Muwa PR dirty-scope classification"
  echo
  echo "Repo: $ROOT"
  echo "Branch: $(git -C "$ROOT" branch --show-current)"
  echo "HEAD: $(git -C "$ROOT" rev-parse HEAD)"
  echo
  if [[ -z "$all_dirty" ]]; then
    echo "No dirty paths."
    exit 0
  fi

  printf '%s\t%s\n' "category" "path" >"$OUT.tsv"
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    printf '%s\t%s\n' "$(classify "$path")" "$path" >>"$OUT.tsv"
  done <<<"$all_dirty"

  echo "## Counts"
  echo
  awk -F '\t' 'NR>1 { count[$1]++ } END { for (c in count) print "- " c ": " count[c] }' "$OUT.tsv" | sort
  echo
  echo "## PR interpretation"
  echo
  echo "- release-guard and coordination-doc paths are expected readiness support."
  echo "- runtime-settings-cache, api-streaming-responses, chat-reasoning-tool-ui, keychain-launch-safety, and model-provider-defaults are likely PR-scope but require review/proof."
  echo "- tests and docs are PR-scope only if they directly support the changed behavior."
  echo "- local-artifact and unknown paths block publication until removed, ignored, or manually classified."
  echo
  for category in release-guard dependency-pin coordination-doc keychain-launch-safety runtime-settings-cache api-streaming-responses chat-reasoning-tool-ui model-provider-defaults tests docs local-artifact unknown; do
    if awk -F '\t' -v c="$category" 'NR>1 && $1 == c { found=1 } END { exit found ? 0 : 1 }' "$OUT.tsv"; then
      echo "## $category"
      echo
      awk -F '\t' -v c="$category" 'NR>1 && $1 == c { print "- `" $2 "`" }' "$OUT.tsv"
      echo
    fi
  done
} >"$OUT"

echo "$OUT"
