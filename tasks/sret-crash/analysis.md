# sret crash — evaluator analysis

## Crash history (3 attempts, all FAIL)

### Attempt 1: @inline(never) performSurfaceCreation (all C interop inside)
- Result: EXC_BAD_ACCESS at 0x20 in GhosttySurfaceCallbackContext.init
- What happened: sret buffer and UUID VWT still overlap in the same stack frame
- Lesson: @inline(never) alone does not prevent sret misallocation WITHIN the function

### Attempt 2: callback context creation moved to caller
- Result: EXC_BAD_ACCESS at 0x0 in ghostty_surface_new (NULL deref)
- What happened: UUID crash gone, but now surfaceConfig is corrupted
- Lesson: sret still corrupts other locals in performSurfaceCreation

### Previous attempts (from memory):
- @inline(never) on individual helpers → crash at rip=0
- @_optimize(none) on createSurface → no crash BUT terminal unresponsive

## Pattern recognition

The sret buffer for ghostty_surface_config_new() corrupts whatever else lives
in the same stack frame, regardless of:
- Function size (large createSurface or small performSurfaceCreation)
- @inline(never) (prevents inlining but optimizer still misallocates WITHIN)

The ONLY approach that prevented the crash was @_optimize(none), which fully
disables the optimizer's stack layout decisions. But on the large createSurface
function, this caused terminal unresponsiveness.

## Key insight

The problem is NOT about which function the code is in.
The problem is that Swift -O misallocates the sret buffer for
ghostty_surface_config_new() specifically. The fix must target
that ONE call, not the surrounding code.

## Hypothesis for next attempt

Create a tiny function that ONLY calls ghostty_surface_config_new() with
@_optimize(none). The function body is a single return statement — no
other variables exist to corrupt. Terminal responsiveness is unaffected
because the function is trivially small.

```swift
@_optimize(none)
private static func safeDefaultSurfaceConfig() -> ghostty_surface_config_s {
    return ghostty_surface_config_new()
}
```

Then in performSurfaceCreation:
```swift
var surfaceConfig = configTemplate ?? Self.safeDefaultSurfaceConfig()
```

This is the MINIMUM intervention that prevents the optimizer from
misallocating the sret buffer.
