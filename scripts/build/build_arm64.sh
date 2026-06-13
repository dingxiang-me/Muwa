#!/usr/bin/env bash
set -euo pipefail

: "${VERSION:?VERSION is required}"

echo "Building ARM64 version (default)..."

if [[ "${ADHOC_SIGNING:-false}" == "true" ]]; then
  echo "Using ad-hoc signing mode (no Apple Developer ID / notarization)."

  rm -rf build/DerivedData build/SourcePackages build_output
  mkdir -p build_output
  xcodebuild -resolvePackageDependencies -workspace Muwa.xcworkspace -scheme Muwa -clonedSourcePackagesDirPath build/SourcePackages -disableAutomaticPackageResolution

  echo "Building CLI (MuwaCLI)..."
  xcodebuild -workspace Muwa.xcworkspace \
    -scheme muwa-cli \
    -configuration Release \
    -derivedDataPath build \
    -clonedSourcePackagesDirPath build/SourcePackages \
    -disableAutomaticPackageResolution \
    ARCHS=arm64 \
    VALID_ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    clean build

  echo "Building App (Muwa)..."
  xcodebuild -workspace Muwa.xcworkspace \
    -scheme Muwa \
    -configuration Release \
    -derivedDataPath build \
    -clonedSourcePackagesDirPath build/SourcePackages \
    -disableAutomaticPackageResolution \
    ARCHS=arm64 \
    VALID_ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${VERSION}" \
    APTABASE_APP_KEY="${APTABASE_APP_KEY:-}" \
    SENTRY_DSN="${SENTRY_DSN:-}" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    build

  BUILT_APP="build/Build/Products/Release/Muwa.app"
  EXPORTED_APP="build_output/Muwa.app"
  CLI_SRC="build/Build/Products/Release/muwa-cli"

  if [[ ! -d "$BUILT_APP" ]]; then
    echo "Error: built app not found at $BUILT_APP" >&2
    exit 1
  fi
  if [[ ! -f "$CLI_SRC" ]]; then
    echo "Error: CLI binary not found at $CLI_SRC" >&2
    exit 1
  fi

  cp -R "$BUILT_APP" "$EXPORTED_APP"
  mkdir -p "$EXPORTED_APP/Contents/Helpers"
  cp "$CLI_SRC" "$EXPORTED_APP/Contents/Helpers/muwa"
  chmod +x "$EXPORTED_APP/Contents/Helpers/muwa"

  echo "Ad-hoc signing exported app bundle..."
  codesign --force --deep --options runtime --entitlements "App/Muwa/muwa.entitlements" --sign - "$EXPORTED_APP"
  exit 0
fi

# Backward-compat: if DEVELOPMENT_TEAM not set, fall back to APPLE_TEAM_ID
if [[ -z "${DEVELOPMENT_TEAM:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  export DEVELOPMENT_TEAM="${APPLE_TEAM_ID}"
fi

: "${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM is required}"
: "${DEVELOPER_ID_NAME:?DEVELOPER_ID_NAME is required}"

# Normalize identity: allow DEVELOPER_ID_NAME with or without the product prefix
CODE_SIGN_IDENTITY_VALUE="${DEVELOPER_ID_NAME}"
if [[ "${CODE_SIGN_IDENTITY_VALUE}" != Developer\ ID\ Application:* ]]; then
  CODE_SIGN_IDENTITY_VALUE="Developer ID Application: ${CODE_SIGN_IDENTITY_VALUE}"
fi

# Ensure a clean build environment before archiving
rm -rf build/DerivedData build/SourcePackages
xcodebuild -resolvePackageDependencies -workspace Muwa.xcworkspace -scheme Muwa -clonedSourcePackagesDirPath build/SourcePackages -disableAutomaticPackageResolution

# 1. Build the CLI first (as a separate scheme)
echo "Building CLI (MuwaCLI)..."
xcodebuild -workspace Muwa.xcworkspace \
  -scheme muwa-cli \
  -configuration Release \
  -derivedDataPath build \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -disableAutomaticPackageResolution \
  ARCHS=arm64 \
  VALID_ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY_VALUE}" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  CODE_SIGN_STYLE=Manual \
  clean build

# 2. Archive the App (which doesn't have the CLI embedded yet via Xcode).
#
# muwa.entitlements carries no profile-managed entitlements (the only one,
# keychain-access-groups, was removed — it shipped without a provisioning
# profile and made AMFI kill the app at launch). Manual Developer ID signing
# therefore archives directly against the entitlements file with no profile.
echo "Archiving App (Muwa)..."
xcodebuild -workspace Muwa.xcworkspace \
  -scheme Muwa \
  -configuration Release \
  -derivedDataPath build \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -disableAutomaticPackageResolution \
  ARCHS=arm64 \
  VALID_ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="${VERSION}" \
  CURRENT_PROJECT_VERSION="${VERSION}" \
  APTABASE_APP_KEY="${APTABASE_APP_KEY:-}" \
  SENTRY_DSN="${SENTRY_DSN:-}" \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY_VALUE}" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  CODE_SIGN_STYLE=Manual \
  archive -archivePath build/Muwa.xcarchive

# 3. Manually Embed the CLI into the Archive
echo "Embedding CLI into Archive (Helpers)..."
CLI_SRC="build/Build/Products/Release/muwa-cli"
ARCHIVE_APP="build/Muwa.xcarchive/Products/Applications/Muwa.app"

if [[ ! -f "$CLI_SRC" ]]; then
  echo "Error: CLI binary not found at $CLI_SRC"
  exit 1
fi

# Copy to Helpers folder as 'muwa'
mkdir -p "$ARCHIVE_APP/Contents/Helpers"
cp "$CLI_SRC" "$ARCHIVE_APP/Contents/Helpers/muwa"
chmod +x "$ARCHIVE_APP/Contents/Helpers/muwa"

# Re-sign the archived app (now carrying the embedded CLI) with the same
# entitlements used for the archive. `--deep` also signs the nested CLI binary
# so Helpers/muwa carries the hardened runtime before export seals the
# bundle. The entitlements file has no profile-managed keys, so export succeeds
# without a provisioning profile and no post-export re-sign is needed.
echo "Re-signing modified app bundle..."
codesign --force --deep --options runtime --entitlements "App/Muwa/muwa.entitlements" --sign "${CODE_SIGN_IDENTITY_VALUE}" "$ARCHIVE_APP"

cat > ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath build/Muwa.xcarchive \
  -exportPath build_output \
  -exportOptionsPlist ExportOptions.plist

EXPORTED_APP="build_output/Muwa.app"
if [[ ! -d "$EXPORTED_APP" ]]; then
  echo "Error: exported app not found at $EXPORTED_APP" >&2
  exit 1
fi
