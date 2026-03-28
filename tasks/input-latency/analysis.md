# Input latency — evaluator analysis

## Measurement data (Claude Code streaming, DEV build)

From typing.phase logs during active Claude Code session:

```
Processing (terminal.keyDown.phase totalMs): 2-9ms — FAST, not the problem
Delay (event creation → processing start):
  Median: ~18ms
  P95:    ~28ms
  Max:    58ms   ← 3-4 frame drops
```

## Root cause analysis

The `delay` is the time between NSEvent creation (by the OS) and when cmux
starts processing it. This time is spent waiting for the main thread to become
available. Something is blocking the main thread runloop.

### Suspects (need to verify each independently):

1. **FileExplorerPanel.gitRepoRoot()** — synchronous `git rev-parse` on main thread
   - File: Sources/Panels/FileExplorerPanel.swift:143-164
   - Called in CWD change sink which runs on main (line 122-130)
   - Process.waitUntilExit() blocks main thread
   - **Severity: HIGH** — process spawn + wait can easily take 20-50ms

2. **FileExplorerPanel.handleFSEvents()** — debounced at 500ms
   - Calls reloadTree() + refreshGitStatus() on main
   - During Claude Code, files change constantly → fires every 500ms
   - reloadTree() does filesystem traversal
   - **Severity: MEDIUM** — depends on tree size

3. **SwiftUI view re-evaluation** — tab title, sidebar updates
   - Terminal output may trigger @Published property changes
   - SwiftUI body re-evaluation on main thread
   - **Severity: UNKNOWN** — need profiling data

4. **ContentView.workspaceObservationCoalesceInterval** — debounce timer
   - Sources/ContentView.swift:11560
   - **Severity: UNKNOWN** — need to check interval

## Fixes applied and results

### Fix 1: gitRepoRoot off main thread
- Moved Process.waitUntilExit() to DispatchQueue.global(qos: .utility)
- CWD debounce 300ms → 500ms, FSEvent debounce 500ms → 1s, git status debounce 500ms → 1s
- Result: No measurable improvement (spikes not caused by this)

### Fix 2: hitTest early return for non-drag events
- Skip NSPasteboard(name: .drag) access when event is not a drag mouse event
- Result: Spikes reduced 10 → 5, but median/P95 unchanged

### Remaining analysis

The 129ms spike shows 577ms gap in the log with no cmux activity — the main
thread is blocked by something outside our code (likely Metal/Ghostty rendering
or AppKit layout). The Debug build adds significant overhead from dlog() calls
and #if DEBUG code paths.

Need to measure with CMUX_KEY_LATENCY_PROBE=1 on a Release build to
distinguish cmux overhead from Debug-only overhead.

## Next steps

1. Verify remaining spikes are Debug-only overhead
2. If spikes persist in Release, investigate Metal rendering / AppKit layout
3. Consider reducing forceRefresh calls during streaming output
