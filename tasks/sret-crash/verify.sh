#!/usr/bin/env bash
# sret crash fix — automated evaluator
# Builds Release, launches, checks for crash, grades against criteria.
#
# Usage: ./tasks/sret-crash/verify.sh
#
# This script is the EVALUATOR. It does not fix anything.
# It only observes and reports.
set -euo pipefail

DERIVED_DATA="DerivedData/cmux-sret-verify"
APP_PATH=""
BUNDLE_ID="com.cmuxterm.app"
REPORT_DIR="$HOME/Library/Logs/DiagnosticReports"
RESULT_FILE="tasks/sret-crash/eval-result.md"

echo "=== sret crash evaluator ==="
echo ""

# Step 1: Record crash report count before
BEFORE_COUNT=$(ls "$REPORT_DIR"/cmux-*.ips 2>/dev/null | wc -l | tr -d ' ')
BEFORE_LATEST=$(ls -t "$REPORT_DIR"/cmux-*.ips 2>/dev/null | head -1 || echo "none")
echo "[1/5] Crash reports before: $BEFORE_COUNT (latest: $(basename "$BEFORE_LATEST" 2>/dev/null || echo none))"

# Step 2: Release build
echo "[2/5] Building Release..."
rm -rf "$DERIVED_DATA"
BUILD_LOG="/tmp/cmux-sret-verify-build.log"
if ! xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" build \
    >"$BUILD_LOG" 2>&1; then
    echo "FAIL: Release build failed"
    echo "  See: $BUILD_LOG"
    cat > "$RESULT_FILE" <<EOF
# Evaluation result: BUILD FAILED
- Criterion 1 (no crash): SKIP
- Criterion 2 (responsive): SKIP
- Criterion 3 (performance): SKIP
- Criterion 4 (simplicity): SKIP
- **Verdict: FAIL** — does not compile in Release
EOF
    exit 1
fi
APP_PATH="$DERIVED_DATA/Build/Products/Release/cmux.app"
echo "  Build succeeded: $APP_PATH"

# Step 3: Kill existing and launch
echo "[3/5] Launching Release app..."
pkill -f "cmux.app/Contents/MacOS/cmux" 2>/dev/null || true
sleep 0.5
open "$APP_PATH"
echo "  Waiting 10 seconds for potential crash..."
sleep 10

# Step 4: Check for new crash reports
AFTER_COUNT=$(ls "$REPORT_DIR"/cmux-*.ips 2>/dev/null | wc -l | tr -d ' ')
AFTER_LATEST=$(ls -t "$REPORT_DIR"/cmux-*.ips 2>/dev/null | head -1 || echo "none")
echo "[4/5] Crash reports after: $AFTER_COUNT (latest: $(basename "$AFTER_LATEST" 2>/dev/null || echo none))"

CRASHED=0
if [ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]; then
    CRASHED=1
    echo "  NEW CRASH DETECTED"
    # Extract crash summary
    CRASH_FILE="$AFTER_LATEST"
    python3 -c "
import json, os
with open('$CRASH_FILE') as f:
    lines = f.readlines()
data = json.loads(''.join(lines[1:]))
exc = data['exception']
ft = data['faultingThread']
thread = data['threads'][ft]
print(f'  Exception: {exc[\"type\"]} {exc[\"subtype\"]}')
frames = thread['frames'][:5]
for i, frame in enumerate(frames):
    img = data['usedImages'][frame['imageIndex']]
    symbol = frame.get('symbol', '')
    src = frame.get('sourceFile', '')
    line = frame.get('sourceLine', '')
    loc = f' ({src}:{line})' if src else ''
    print(f'    {i}: {img.get(\"name\",\"?\")} {symbol}{loc}')
" 2>/dev/null || echo "  (could not parse crash report)"
else
    echo "  No new crashes"
fi

# Check if process is still running
RUNNING=0
if pgrep -f "cmux.app/Contents/MacOS/cmux" >/dev/null 2>&1; then
    RUNNING=1
    echo "  App is still running"
else
    echo "  App is NOT running"
    if [ "$CRASHED" -eq 0 ]; then
        CRASHED=1
        echo "  (process exited without crash report — may have crashed too fast)"
    fi
fi

# Step 5: Grade
echo ""
echo "[5/5] Grading..."
echo ""

C1="FAIL"
C2="UNTESTED"
if [ "$CRASHED" -eq 0 ] && [ "$RUNNING" -eq 1 ]; then
    C1="PASS"
    C2="MANUAL — type 'cd /tmp && ls' in terminal, verify output, then run second command"
else
    C2="SKIP — app crashed"
fi

cat > "$RESULT_FILE" <<EOF
# Evaluation result
Date: $(date '+%Y-%m-%d %H:%M:%S')
Build: Release
Crash reports before: $BEFORE_COUNT
Crash reports after: $AFTER_COUNT

## Grades
- Criterion 1 (no crash on launch): **$C1**
- Criterion 2 (terminal responsive): **$C2**
- Criterion 3 (performance impact): MANUAL — review code for @_optimize(none) scope
- Criterion 4 (code simplicity): MANUAL — review diff size and new functions

## Crash details
EOF

if [ "$CRASHED" -eq 1 ] && [ -f "$AFTER_LATEST" ]; then
    python3 -c "
import json
with open('$AFTER_LATEST') as f:
    lines = f.readlines()
data = json.loads(''.join(lines[1:]))
exc = data['exception']
ft = data['faultingThread']
thread = data['threads'][ft]
print(f'Exception: {exc[\"type\"]} {exc[\"subtype\"]}')
print(f'Faulting thread: {ft}')
print()
for i, frame in enumerate(thread['frames'][:15]):
    img = data['usedImages'][frame['imageIndex']]
    symbol = frame.get('symbol', '')
    src = frame.get('sourceFile', '')
    line = frame.get('sourceLine', '')
    loc = f'  ({src}:{line})' if src else ''
    print(f'  {i:2d}: {img.get(\"name\",\"?\")} {symbol}{loc}')
" >> "$RESULT_FILE" 2>/dev/null || echo "Could not parse crash" >> "$RESULT_FILE"
else
    echo "No crash" >> "$RESULT_FILE"
fi

echo ""
echo "=== Evaluation written to: $RESULT_FILE ==="
cat "$RESULT_FILE"
