# Typing Burst Mode

Defer non-essential UI updates during active typing to improve perceived terminal responsiveness.

## Problem

Terminal typing competes for main thread time with sidebar updates, file explorer git status refreshes, session autosave, port scanning, and git metadata polling. These updates are individually debounced but still collectively create jank during fast typing.

## Approach

Detect "typing bursts" via keystroke interval (200ms threshold). During a burst, all non-essential UI updates are suppressed. When the burst ends, deferred work flushes once.

## Components

### TypingBurstTracker

New file: `Sources/TypingBurstTracker.swift`

```swift
@MainActor
final class TypingBurstTracker {
    static let shared = TypingBurstTracker()

    private(set) var isBursting: Bool = false  // NOT @Published — avoid SwiftUI re-evaluation
    private(set) var lastKeystrokeAt: TimeInterval = 0  // systemUptime, replaces AppDelegate.lastTypingActivityAt

    static let burstThreshold: TimeInterval = 0.2  // 200ms

    // NotificationCenter notifications
    static let burstDidBeginNotification = Notification.Name("TypingBurstDidBegin")
    static let burstDidEndNotification = Notification.Name("TypingBurstDidEnd")

    func markKeystroke() {
        let now = ProcessInfo.processInfo.systemUptime
        lastKeystrokeAt = now
        let wasAlreadyBursting = isBursting

        if !isBursting {
            isBursting = true
            NotificationCenter.default.post(name: Self.burstDidBeginNotification, object: nil)
        }

        // Schedule a single delayed check — no timer management
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.burstThreshold) { [weak self] in
            guard let self else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - self.lastKeystrokeAt
            if elapsed >= Self.burstThreshold {
                self.isBursting = false
                NotificationCenter.default.post(name: Self.burstDidEndNotification, object: nil)
            }
            // else: another keystroke came in, that keystroke's asyncAfter will handle end detection
        }
    }
}
```

### Integration point

In the custom NSWindow subclass `sendEvent(_:)` (AppDelegate.swift ~line 12414):

```swift
if event.type == .keyDown {
    TypingBurstTracker.shared.markKeystroke()
    // Remove: AppDelegate.shared?.recordTypingActivity() — now handled by TypingBurstTracker.lastKeystrokeAt
}
```

### recordTypingActivity() migration

`AppDelegate.recordTypingActivity()` and `lastTypingActivityAt` are removed. `remainingSessionAutosaveTypingQuietPeriod()` reads from `TypingBurstTracker.shared.lastKeystrokeAt` instead.

### Deferred work consumers

Each consumer observes `.burstDidEndNotification` to flush deferred work:

| Consumer | File | Burst behavior |
|----------|------|----------------|
| Panel title updates | TabManager.swift | `NotificationBurstCoalescer` flush suppressed during burst; flush on burst end |
| Session autosave | AppDelegate.swift | `remainingSessionAutosaveTypingQuietPeriod` reads from tracker; natural deferral continues |
| File explorer git status | FileExplorerPanel.swift | Debounce timer not started during burst; kick on burst end |
| File explorer FSEvents | FileExplorerPanel.swift | Tree reload queued (not executed) during burst; single reload on burst end |
| Port scanner | PortScanner.swift | `kick()` dropped during burst; single kick on burst end |
| Git metadata polling | TabManager.swift | Timer fire during burst is skipped; execute on burst end |

### What does NOT change

- Terminal rendering (Ghostty/Metal `forceRefresh()`) — never deferred
- IME composition — included in burst detection (same keyDown path)
- `sendEvent` timing telemetry — unchanged

## Constraints

- `markKeystroke()` must be zero-allocation on the hot path (timestamp write + asyncAfter only)
- No `@Published` on `TypingBurstTracker` — prevents SwiftUI subscription
- Burst threshold (200ms) is hardcoded; can be made configurable later if needed
- All deferred items gracefully degrade — worst case is delayed updates, never lost updates

## Testing

Unit tests for `TypingBurstTracker`:
- Burst start on first keystroke
- Burst continuation on rapid keystrokes (< 200ms apart)
- Burst end after 200ms idle
- Single keystroke creates a burst that ends after 200ms
- `lastKeystrokeAt` correctly updated on each call
- NotificationCenter posts at correct times

Integration: verify each consumer correctly defers and flushes (CI only).
