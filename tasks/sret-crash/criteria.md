# sret crash fix — evaluation criteria

Each criterion has a PASS/FAIL threshold. ALL must pass for the fix to ship.

## 1. No crash on launch (HARD GATE)
- Release build on this Intel Mac launches without EXC_BAD_ACCESS
- No new crash report in ~/Library/Logs/DiagnosticReports/ within 10 seconds of launch
- Grade: PASS if no crash, FAIL if any crash

## 2. Terminal responsiveness (HARD GATE)
- After launch, can type commands in terminal
- `cd /tmp && ls` executes and shows output
- Second command also works (not frozen after first)
- Grade: PASS if interactive, FAIL if frozen/unresponsive

## 3. Performance impact (SOFT GATE)
- No @_optimize(none) on functions larger than 20 lines
- No broad optimization disabling (whole-module, etc.)
- Keystroke latency not noticeably degraded
- Grade: PASS if targeted, WARN if broad but functional

## 4. Code simplicity (SOFT GATE)
- Fix is understandable in isolation without reading the crash history
- No more than 1 new function introduced
- No architecture changes beyond the crash fix scope
- Grade: PASS if minimal, WARN if complex but correct
