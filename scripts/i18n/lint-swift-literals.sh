#!/usr/bin/env bash
# Flag SwiftUI / AppKit literal patterns that bypass the MuwaCore catalog.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$ROOT/scripts/i18n/lint-swift-literals.py"
