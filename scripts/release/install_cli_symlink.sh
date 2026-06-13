#!/bin/bash
set -euo pipefail

# install_cli_symlink.sh
# Creates/updates a convenient `muwa` symlink to either:
#   1) the app's embedded CLI at Muwa.app/Contents/Helpers/muwa, or
#   2) a locally built CLI binary in DerivedData (dev mode).
#
# Usage:
#   scripts/install_cli_symlink.sh [--dev] [--prefix <dir>] [<path-to-Muwa.app>]
#
# Notes:
# - When no path is provided, common install locations are checked.
# - On Apple Silicon, Homebrew typically lives at /opt/homebrew; we auto-detect it.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DEV_MODE=0
PREFIX_OVERRIDE=""
APP_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev)
      DEV_MODE=1
      shift
      ;;
    --prefix)
      PREFIX_OVERRIDE="${2:-}"
      if [[ -z "$PREFIX_OVERRIDE" ]]; then
        echo "--prefix requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      # Positional: optional path to .app
      APP_PATH="$1"
      shift
      ;;
  esac
done

resolve_cli_from_app() {
  local app_path="$1"
  local candidate
  for candidate in \
    "$app_path/Contents/Helpers/muwa" \
    "$app_path/Contents/MacOS/muwa" \
    "$app_path/Contents/MacOS/muwa" \
    "$app_path/Contents/Helpers/muwa" \
    "$app_path/Contents/MacOS/muwa"
  do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_cli_from_dev() {
  # Try common DerivedData product locations
  local base="$REPO_ROOT/build/DerivedData/Build/Products/Release"
  for candidate in \
    "$base/muwa" \
    "$base/muwa-cli" \
    "$base/Muwa.app/Contents/Helpers/muwa" \
    "$base/Muwa.app/Contents/MacOS/muwa" \
    "$base/muwa" \
    "$base/muwa-cli" \
    "$base/Muwa.app/Contents/Helpers/muwa" \
    "$base/Muwa.app/Contents/MacOS/muwa" \
    "$REPO_ROOT/build/DerivedData/Build/Products/Debug/muwa" \
    "$REPO_ROOT/build/DerivedData/Build/Products/Debug/muwa-cli" \
    "$REPO_ROOT/build/DerivedData/Build/Products/Debug/Muwa.app/Contents/Helpers/muwa" \
    "$REPO_ROOT/build/DerivedData/Build/Products/Debug/Muwa.app/Contents/MacOS/muwa" \
    "$REPO_ROOT/build/DerivedData/Build/Products/Debug/muwa" \
    "$REPO_ROOT/build/DerivedData/Build/Products/Debug/muwa-cli" \
    "$REPO_ROOT/build/DerivedData/Build/Products/Debug/Muwa.app/Contents/Helpers/muwa" \
    "$REPO_ROOT/build/DerivedData/Build/Products/Debug/Muwa.app/Contents/MacOS/muwa"
  do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_target_bin_dir() {
  # Priority: explicit --prefix, Homebrew prefix/bin, /usr/local/bin, ~/.local/bin
  if [[ -n "$PREFIX_OVERRIDE" ]]; then
    echo "$PREFIX_OVERRIDE/bin"
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    local brew_prefix
    brew_prefix="$(brew --prefix 2>/dev/null || true)"
    if [[ -n "$brew_prefix" ]]; then
      echo "$brew_prefix/bin"
      return 0
    fi
  fi

  if [[ -d "/usr/local/bin" ]]; then
    echo "/usr/local/bin"
    return 0
  fi

  echo "$HOME/.local/bin"
}

# Determine CLI source
CLI_SRC=""
if [[ "$DEV_MODE" == "1" ]]; then
  if CLI_SRC="$(resolve_cli_from_dev)"; then :; else
    echo "Could not locate a built CLI in DerivedData. Build it first: 'make cli'" >&2
    exit 1
  fi
else
  if [[ -z "$APP_PATH" ]]; then
    CANDIDATES=(
      "/Applications/Muwa.app"
      "$HOME/Applications/Muwa.app"
      "/Applications/muwa.app"
      "$HOME/Applications/muwa.app"
      "/Applications/Muwa.app"
      "$HOME/Applications/Muwa.app"
      "/Applications/Muwa.app"
      "$HOME/Applications/Muwa.app"
    )
    for c in "${CANDIDATES[@]}"; do
      if CLI_SRC="$(resolve_cli_from_app "$c")"; then
        APP_PATH="$c"
        break
      fi
    done
  else
    if CLI_SRC="$(resolve_cli_from_app "$APP_PATH")"; then :; else
      echo "CLI binary not found in: $APP_PATH" >&2
      echo "Expected at: $APP_PATH/Contents/Helpers/muwa" >&2
      exit 1
    fi
  fi

  if [[ -z "$CLI_SRC" ]]; then
    echo "Could not locate Muwa.app automatically. Provide the path explicitly." >&2
    echo "Example: scripts/install_cli_symlink.sh '/Applications/Muwa.app'" >&2
    exit 1
  fi
fi

TARGET_DIR="$(resolve_target_bin_dir)"
TARGET_LINK="$TARGET_DIR/muwa"

mkdir -p "$TARGET_DIR"

if [[ -w "$TARGET_DIR" ]]; then
  ln -sf "$CLI_SRC" "$TARGET_LINK"
  echo "Installed symlink: $TARGET_LINK -> $CLI_SRC"
else
  # Fallback to user-local, avoid sudo prompts
  TARGET_DIR="$HOME/.local/bin"
  mkdir -p "$TARGET_DIR"
  TARGET_LINK="$TARGET_DIR/muwa"
  ln -sf "$CLI_SRC" "$TARGET_LINK"
  echo "Installed symlink (user): $TARGET_LINK -> $CLI_SRC"
  echo "Make sure $TARGET_DIR is on your PATH (e.g., add to your shell profile)."
fi
