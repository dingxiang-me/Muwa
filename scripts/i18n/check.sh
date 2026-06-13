#!/usr/bin/env bash
# Validate required Muwa string catalogs (used by CI and locally).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PY="${ROOT}/scripts/i18n/check-localizations.py"
LOCALES="de,zh-Hans"

python3 "$PY" --catalog "$ROOT/Packages/MuwaCore/Resources/Localizable.xcstrings" --required-locales "$LOCALES"
python3 "$PY" --catalog "$ROOT/App/Muwa/InfoPlist.xcstrings" --required-locales "$LOCALES"
python3 "$ROOT/scripts/i18n/check-swift-catalog-keys.py" \
    --catalog "$ROOT/Packages/MuwaCore/Resources/Localizable.xcstrings" \
    --swift-root "$ROOT/Packages/MuwaCore"

bash "$ROOT/scripts/i18n/lint-swift-literals.sh"
