#!/usr/bin/env bash
set -euo pipefail

brew install create-dmg

# ARM64 DMG (no arch suffix)
create-dmg \
  --background "$GITHUB_WORKSPACE/assets/dmg-bg.tiff" \
  --volname "Muwa" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "Muwa.app" 150 185 \
  --hide-extension "Muwa.app" \
  --app-drop-link 450 185 \
  "build_output/Muwa-${VERSION}.dmg" \
  "build_output/Muwa.app" || true

if [ ! -f "build_output/Muwa-${VERSION}.dmg" ]; then
  echo "create-dmg failed, using basic DMG creation"
  hdiutil create -volname "Muwa" \
    -srcfolder "build_output/Muwa.app" \
    -ov -format UDZO \
    "build_output/Muwa-${VERSION}.dmg"
fi

if [[ "${ADHOC_SIGNING:-false}" == "true" ]]; then
  echo "Ad-hoc signing DMG..."
  codesign --force --sign - "build_output/Muwa-${VERSION}.dmg"
else
  : "${DEVELOPER_ID_NAME:?DEVELOPER_ID_NAME is required}"
  # Normalize identity: allow DEVELOPER_ID_NAME with or without the product prefix
  CODE_SIGN_IDENTITY_VALUE="${DEVELOPER_ID_NAME}"
  if [[ "${CODE_SIGN_IDENTITY_VALUE}" != Developer\ ID\ Application:* ]]; then
    CODE_SIGN_IDENTITY_VALUE="Developer ID Application: ${CODE_SIGN_IDENTITY_VALUE}"
  fi

  codesign --force --sign "${CODE_SIGN_IDENTITY_VALUE}" \
    "build_output/Muwa-${VERSION}.dmg"
fi

cp "build_output/Muwa-${VERSION}.dmg" "build_output/Muwa.dmg"

