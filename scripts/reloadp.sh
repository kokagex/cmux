#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${SCRIPT_DIR}/DerivedData"

XCODE_LOG="/tmp/cmux-release-build.log"
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Release -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" build 2>&1 | tee "$XCODE_LOG" | grep -E '(warning:|error:|fatal:|BUILD FAILED|BUILD SUCCEEDED|\*\* BUILD)'
XCODE_EXIT=${PIPESTATUS[0]}
if [[ "$XCODE_EXIT" -ne 0 ]]; then
  echo "Build failed (exit $XCODE_EXIT). Full log: $XCODE_LOG" >&2
  exit "$XCODE_EXIT"
fi
echo "/tmp/cmux-release-build.log" > /tmp/cmux-last-release-log-path
pkill -x cmux || true
sleep 0.2
APP_PATH="${DERIVED_DATA}/Build/Products/Release/cmux.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "cmux.app not found at ${APP_PATH}" >&2
  exit 1
fi
# Ensure the bundle timestamp reflects the latest build so Finder shows it correctly.
touch "$APP_PATH"

echo "Release app:"
echo "  ${APP_PATH}"

# Dev shells (including CI/Codex) often force-disable paging by exporting these.
# Don't leak that into cmux, otherwise `git diff` won't page even with PAGER=less.
env -u GIT_PAGER -u GH_PAGER open -g "$APP_PATH"

APP_PROCESS_PATH="${APP_PATH}/Contents/MacOS/cmux"
ATTEMPT=0
MAX_ATTEMPTS=20
while [[ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]]; do
  if pgrep -f "$APP_PROCESS_PATH" >/dev/null 2>&1; then
    echo "Release launch status:"
    echo "  running: ${APP_PROCESS_PATH}"
    exit 0
  fi
  ATTEMPT=$((ATTEMPT + 1))
  sleep 0.25
done

echo "warning: Release app launch was requested, but no running process was observed for:" >&2
echo "  ${APP_PROCESS_PATH}" >&2
