# Typing Burst Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Defer non-essential UI updates during active typing to improve perceived terminal responsiveness.

**Architecture:** A `TypingBurstTracker` singleton detects typing bursts (keystroke interval < 200ms). During a burst, consumers skip or queue non-essential work. On burst end, a single `NotificationCenter` notification triggers deferred flushes. The tracker also subsumes `AppDelegate.recordTypingActivity()` by exposing `lastKeystrokeAt`.

**Tech Stack:** Swift, AppKit, NotificationCenter

**Spec:** `docs/superpowers/specs/2026-03-28-typing-burst-mode-design.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `Sources/TypingBurstTracker.swift` | Burst detection: timestamp + asyncAfter, notifications |
| Create | `cmuxTests/TypingBurstTrackerTests.swift` | Unit tests for burst lifecycle |
| Modify | `Sources/AppDelegate.swift:12414-12415` | Replace `recordTypingActivity()` with `markKeystroke()` |
| Modify | `Sources/AppDelegate.swift:2212,2226,3557-3662` | Remove `lastTypingActivityAt`, `recordTypingActivity()`; redirect `remainingSessionAutosaveTypingQuietPeriod()` |
| Modify | `Sources/TabManager.swift:447-479` | Add burst-aware suppression to `NotificationBurstCoalescer` |
| Modify | `Sources/TabManager.swift:906-918` | Skip git metadata poll during burst |
| Modify | `Sources/Panels/FileExplorerPanel.swift:314-323,419-428` | Defer git status + FSEvents during burst |
| Modify | `Sources/PortScanner.swift:65-75` | Drop `kick()` during burst |
| Modify | `GhosttyTabs.xcodeproj/project.pbxproj` | Add new source and test files |

---

### Task 1: Create TypingBurstTracker

**Files:**
- Create: `Sources/TypingBurstTracker.swift`

- [ ] **Step 1: Create TypingBurstTracker.swift**

```swift
import Foundation

/// Detects typing bursts (rapid consecutive keystrokes) and notifies consumers
/// so they can defer non-essential work during active typing.
///
/// Call `markKeystroke()` on every `keyDown` event. When keystrokes arrive
/// within `burstThreshold` (200ms), the tracker enters burst mode.
/// On burst end, `.burstDidEndNotification` fires so consumers can flush
/// deferred work.
///
/// Also provides `lastKeystrokeAt` (systemUptime) for session autosave
/// quiet-period calculation, replacing the former `AppDelegate.recordTypingActivity()`.
@MainActor
final class TypingBurstTracker {
    static let shared = TypingBurstTracker()

    /// Whether a typing burst is currently active.
    /// NOT @Published — consumers must use NotificationCenter to avoid
    /// triggering SwiftUI re-evaluation during typing.
    private(set) var isBursting: Bool = false

    /// System uptime of the last keystroke. Used by session autosave
    /// to calculate the typing quiet period.
    private(set) var lastKeystrokeAt: TimeInterval = 0

    /// Minimum idle interval (seconds) before a burst is considered ended.
    static let burstThreshold: TimeInterval = 0.2

    static let burstDidBeginNotification = Notification.Name("TypingBurstDidBegin")
    static let burstDidEndNotification = Notification.Name("TypingBurstDidEnd")

    private init() {}

    /// Record a keystroke. Call from the window-level `sendEvent` on every `keyDown`.
    func markKeystroke() {
        let now = ProcessInfo.processInfo.systemUptime
        lastKeystrokeAt = now

        if !isBursting {
            isBursting = true
            NotificationCenter.default.post(name: Self.burstDidBeginNotification, object: nil)
        }

        // Schedule a delayed check. If no new keystroke arrived within the threshold,
        // the burst is over. Each keystroke schedules its own check; only the last one
        // will actually end the burst (because `lastKeystrokeAt` will have advanced
        // past earlier checks).
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.burstThreshold) { [weak self] in
            guard let self else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - self.lastKeystrokeAt
            if elapsed >= Self.burstThreshold {
                self.isBursting = false
                NotificationCenter.default.post(name: Self.burstDidEndNotification, object: nil)
            }
        }
    }
}
```

- [ ] **Step 2: Add file to Xcode project**

Open `GhosttyTabs.xcodeproj/project.pbxproj` and add `TypingBurstTracker.swift` to the Sources group and cmux target build phase. Follow the pattern of `TerminalNotificationStore.swift` (line 55, 245, 462, 773 in pbxproj).

- [ ] **Step 3: Commit**

```bash
git add Sources/TypingBurstTracker.swift GhosttyTabs.xcodeproj/project.pbxproj
git commit -m "feat: add TypingBurstTracker for typing burst detection"
```

---

### Task 2: Write TypingBurstTracker unit tests

**Files:**
- Create: `cmuxTests/TypingBurstTrackerTests.swift`

- [ ] **Step 1: Create test file**

```swift
import XCTest
@testable import cmux

@MainActor
final class TypingBurstTrackerTests: XCTestCase {

    private var tracker: TypingBurstTracker!

    override func setUp() {
        super.setUp()
        tracker = TypingBurstTracker.shared
    }

    override func tearDown() {
        // Allow any pending burst to end before next test.
        // The singleton persists, so we wait for isBursting to clear.
        let timeout = Date().addingTimeInterval(1.0)
        while tracker.isBursting, Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        super.tearDown()
    }

    // MARK: - Burst lifecycle

    func testMarkKeystrokeStartsBurst() {
        let expectation = expectation(forNotification: TypingBurstTracker.burstDidBeginNotification, object: nil)
        tracker.markKeystroke()
        XCTAssertTrue(tracker.isBursting)
        wait(for: [expectation], timeout: 1.0)
    }

    func testBurstEndsAfterThreshold() {
        let endExpectation = expectation(forNotification: TypingBurstTracker.burstDidEndNotification, object: nil)
        tracker.markKeystroke()
        XCTAssertTrue(tracker.isBursting)
        wait(for: [endExpectation], timeout: 1.0)
        XCTAssertFalse(tracker.isBursting)
    }

    func testRapidKeystrokesSustainBurst() {
        tracker.markKeystroke()
        XCTAssertTrue(tracker.isBursting)

        // Send keystrokes every 100ms (< 200ms threshold) for 500ms total
        for i in 1...5 {
            let sustainExpectation = expectation(description: "sustain \(i)")
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) {
                self.tracker.markKeystroke()
                XCTAssertTrue(self.tracker.isBursting, "Should still be bursting at keystroke \(i)")
                sustainExpectation.fulfill()
            }
        }
        waitForExpectations(timeout: 2.0)
        XCTAssertTrue(tracker.isBursting, "Should still be bursting immediately after last keystroke")
    }

    func testLastKeystrokeAtUpdated() {
        let before = ProcessInfo.processInfo.systemUptime
        tracker.markKeystroke()
        let after = ProcessInfo.processInfo.systemUptime
        XCTAssertGreaterThanOrEqual(tracker.lastKeystrokeAt, before)
        XCTAssertLessThanOrEqual(tracker.lastKeystrokeAt, after)
    }

    func testBurstDidEndNotificationFires() {
        let beginExpectation = expectation(forNotification: TypingBurstTracker.burstDidBeginNotification, object: nil)
        let endExpectation = expectation(forNotification: TypingBurstTracker.burstDidEndNotification, object: nil)
        tracker.markKeystroke()
        wait(for: [beginExpectation], timeout: 1.0)
        wait(for: [endExpectation], timeout: 1.0)
    }
}
```

- [ ] **Step 2: Add test file to Xcode project**

Add `TypingBurstTrackerTests.swift` to the cmuxTests target in `project.pbxproj`.

- [ ] **Step 3: Commit**

```bash
git add cmuxTests/TypingBurstTrackerTests.swift GhosttyTabs.xcodeproj/project.pbxproj
git commit -m "test: add TypingBurstTracker unit tests"
```

---

### Task 3: Integrate into sendEvent and remove recordTypingActivity

**Files:**
- Modify: `Sources/AppDelegate.swift:12414-12415` — replace `recordTypingActivity()` call
- Modify: `Sources/AppDelegate.swift:2212` — remove `lastTypingActivityAt` property
- Modify: `Sources/AppDelegate.swift:3557-3563` — update `remainingSessionAutosaveTypingQuietPeriod()`
- Modify: `Sources/AppDelegate.swift:3660-3662` — remove `recordTypingActivity()`

- [ ] **Step 1: Replace recordTypingActivity() call in sendEvent**

In `Sources/AppDelegate.swift`, find the `cmux_sendEvent` method (line 12390). Replace lines 12412-12415:

```swift
// BEFORE (lines 12412-12415):
        // recordTypingActivity must run in all builds so runSessionAutosaveTick
        // can honor the typing quiet period in release.
        if event.type == .keyDown {
            AppDelegate.shared?.recordTypingActivity()
        }

// AFTER:
        // TypingBurstTracker records keystroke timing for both burst detection
        // and session autosave typing quiet period. Must run in all builds.
        if event.type == .keyDown {
            TypingBurstTracker.shared.markKeystroke()
        }
```

- [ ] **Step 2: Update remainingSessionAutosaveTypingQuietPeriod()**

In `Sources/AppDelegate.swift`, replace the method (lines 3557-3563):

```swift
// BEFORE:
    private func remainingSessionAutosaveTypingQuietPeriod(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval? {
        guard lastTypingActivityAt > 0 else { return nil }
        let elapsed = nowUptime - lastTypingActivityAt
        guard elapsed < Self.sessionAutosaveTypingQuietPeriod else { return nil }
        return Self.sessionAutosaveTypingQuietPeriod - elapsed
    }

// AFTER:
    private func remainingSessionAutosaveTypingQuietPeriod(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval? {
        let lastKeystroke = TypingBurstTracker.shared.lastKeystrokeAt
        guard lastKeystroke > 0 else { return nil }
        let elapsed = nowUptime - lastKeystroke
        guard elapsed < Self.sessionAutosaveTypingQuietPeriod else { return nil }
        return Self.sessionAutosaveTypingQuietPeriod - elapsed
    }
```

- [ ] **Step 3: Remove lastTypingActivityAt and recordTypingActivity()**

In `Sources/AppDelegate.swift`:

Remove line 2212:
```swift
    private var lastTypingActivityAt: TimeInterval = 0
```

Remove lines 3660-3662:
```swift
    fileprivate func recordTypingActivity() {
        lastTypingActivityAt = ProcessInfo.processInfo.systemUptime
    }
```

- [ ] **Step 4: Verify compilation**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-burst build 2>&1 | tail -5
```

Expected: **BUILD SUCCEEDED**

- [ ] **Step 5: Commit**

```bash
git add Sources/AppDelegate.swift
git commit -m "refactor: replace recordTypingActivity with TypingBurstTracker"
```

---

### Task 4: Defer panel title updates during burst

**Files:**
- Modify: `Sources/TabManager.swift:447-479` — add burst awareness to `NotificationBurstCoalescer`

- [ ] **Step 1: Add burst suppression to NotificationBurstCoalescer**

In `Sources/TabManager.swift`, replace the `NotificationBurstCoalescer` class (lines 447-480):

```swift
final class NotificationBurstCoalescer {
    private let delay: TimeInterval
    private var isFlushScheduled = false
    private var pendingAction: (() -> Void)?
    private var suppressedDuringBurst = false
    private var burstEndObserver: NSObjectProtocol?

    init(delay: TimeInterval = 1.0 / 30.0) {
        self.delay = max(0, delay)
        burstEndObserver = NotificationCenter.default.addObserver(
            forName: TypingBurstTracker.burstDidEndNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.suppressedDuringBurst else { return }
            self.suppressedDuringBurst = false
            self.flush()
        }
    }

    deinit {
        if let observer = burstEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func signal(_ action: @escaping () -> Void) {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        pendingAction = action
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.tryFlush()
        }
    }

    private func tryFlush() {
        isFlushScheduled = false
        if TypingBurstTracker.shared.isBursting {
            suppressedDuringBurst = true
            return
        }
        flush()
    }

    private func flush() {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        isFlushScheduled = false
        suppressedDuringBurst = false
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
        if pendingAction != nil {
            scheduleFlushIfNeeded()
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/TabManager.swift
git commit -m "feat: defer panel title coalescer flush during typing burst"
```

---

### Task 5: Skip git metadata poll during burst

**Files:**
- Modify: `Sources/TabManager.swift:910-914` — guard against burst in poll handler

- [ ] **Step 1: Add burst guard to git metadata poll**

In `Sources/TabManager.swift`, find `startWorkspaceGitMetadataPollTimer()` (line 906). Modify the event handler (lines 910-914):

```swift
// BEFORE:
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshTrackedWorkspaceGitMetadata()
            }
        }

// AFTER:
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if TypingBurstTracker.shared.isBursting {
                    // Skip this tick; burstDidEnd will trigger a refresh.
                    return
                }
                self.refreshTrackedWorkspaceGitMetadata()
            }
        }
```

- [ ] **Step 2: Add burst-end observer for deferred git refresh**

Find the `init()` of `TabManager` (or a suitable setup method) and add an observer. Place it near the existing `startWorkspaceGitMetadataPollTimer()` call:

```swift
NotificationCenter.default.addObserver(
    forName: TypingBurstTracker.burstDidEndNotification,
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.refreshTrackedWorkspaceGitMetadata()
}
```

Store the observer in a property to avoid leaks (follow existing observer patterns in TabManager).

- [ ] **Step 3: Commit**

```bash
git add Sources/TabManager.swift
git commit -m "feat: skip git metadata poll during typing burst"
```

---

### Task 6: Defer file explorer git status and FSEvents during burst

**Files:**
- Modify: `Sources/Panels/FileExplorerPanel.swift:314-323` — guard `refreshGitStatus()`
- Modify: `Sources/Panels/FileExplorerPanel.swift:419-428` — guard `handleFSEvents()`

- [ ] **Step 1: Add burst guard and deferred flush to FileExplorerPanel**

Add properties and burst-end observer to `FileExplorerPanel` (near existing debounce properties):

```swift
private var gitStatusDeferredDuringBurst = false
private var fsEventsDeferredDuringBurst = false
private var burstEndObserver: NSObjectProtocol?
```

In the initializer or setup method, add:

```swift
burstEndObserver = NotificationCenter.default.addObserver(
    forName: TypingBurstTracker.burstDidEndNotification,
    object: nil,
    queue: .main
) { [weak self] _ in
    guard let self, !self.isClosed else { return }
    if self.fsEventsDeferredDuringBurst {
        self.fsEventsDeferredDuringBurst = false
        self.reloadTree()
    }
    if self.gitStatusDeferredDuringBurst {
        self.gitStatusDeferredDuringBurst = false
        self.performGitStatusRefresh()
    }
}
```

In `deinit` or cleanup:
```swift
if let observer = burstEndObserver {
    NotificationCenter.default.removeObserver(observer)
}
```

- [ ] **Step 2: Guard refreshGitStatus()**

In `Sources/Panels/FileExplorerPanel.swift`, modify `refreshGitStatus()` (line 314):

```swift
// BEFORE:
    func refreshGitStatus() {
        gitStatusDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.performGitStatusRefresh()
            }
        }
        gitStatusDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

// AFTER:
    func refreshGitStatus() {
        if TypingBurstTracker.shared.isBursting {
            gitStatusDeferredDuringBurst = true
            return
        }
        gitStatusDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.performGitStatusRefresh()
            }
        }
        gitStatusDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
```

- [ ] **Step 3: Guard handleFSEvents()**

In `Sources/Panels/FileExplorerPanel.swift`, modify `handleFSEvents()` (line 419):

```swift
// BEFORE:
    func handleFSEvents() {
        fsEventDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed else { return }
            self.reloadTree()
            self.refreshGitStatus()
        }
        fsEventDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

// AFTER:
    func handleFSEvents() {
        if TypingBurstTracker.shared.isBursting {
            fsEventsDeferredDuringBurst = true
            return
        }
        fsEventDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed else { return }
            self.reloadTree()
            self.refreshGitStatus()
        }
        fsEventDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
```

- [ ] **Step 4: Commit**

```bash
git add Sources/Panels/FileExplorerPanel.swift
git commit -m "feat: defer file explorer git status and FSEvents during typing burst"
```

---

### Task 7: Drop port scanner kicks during burst

**Files:**
- Modify: `Sources/PortScanner.swift:65-75` — guard `kick()`

- [ ] **Step 1: Add burst guard to kick()**

In `Sources/PortScanner.swift`, modify `kick()` (line 65). Since `PortScanner` runs on its own `queue` (not main thread), check burst state on main:

```swift
// BEFORE:
    func kick(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            guard ttyNames[key] != nil else { return }
            pendingKicks.insert(key)

            if !burstActive {
                startCoalesce()
            }
            // If burst is active, the next scan iteration will pick up the new kick.
        }

// AFTER:
    func kick(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            guard ttyNames[key] != nil else { return }

            // Check typing burst on main actor. If bursting, mark deferred
            // and skip; burstDidEnd will re-kick.
            let typingBursting = DispatchQueue.main.sync {
                TypingBurstTracker.shared.isBursting
            }
            if typingBursting {
                deferredKickKeys.insert(key)
                return
            }

            pendingKicks.insert(key)

            if !burstActive {
                startCoalesce()
            }
        }
    }
```

- [ ] **Step 2: Add deferred kick storage and burst-end observer**

Add a property to `PortScanner`:

```swift
private var deferredKickKeys = Set<PanelKey>()
private var burstEndObserver: NSObjectProtocol?
```

In the initializer, add:

```swift
burstEndObserver = NotificationCenter.default.addObserver(
    forName: TypingBurstTracker.burstDidEndNotification,
    object: nil,
    queue: .main
) { [weak self] _ in
    guard let self else { return }
    self.queue.async { [self] in
        guard !self.deferredKickKeys.isEmpty else { return }
        self.pendingKicks.formUnion(self.deferredKickKeys)
        self.deferredKickKeys.removeAll()
        if !self.burstActive {
            self.startCoalesce()
        }
    }
}
```

In `deinit`:
```swift
if let observer = burstEndObserver {
    NotificationCenter.default.removeObserver(observer)
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/PortScanner.swift
git commit -m "feat: defer port scanner kicks during typing burst"
```

---

### Task 8: Verify build and add to pitfalls doc

**Files:**
- Modify: `.claude/rules/pitfalls.md` — document burst tracker as typing-latency-sensitive

- [ ] **Step 1: Verify full build**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-burst build 2>&1 | tail -5
```

Expected: **BUILD SUCCEEDED**

- [ ] **Step 2: Add pitfall entry**

Append to `.claude/rules/pitfalls.md` under `## Typing-latency-sensitive paths`:

```markdown
- **`TypingBurstTracker.markKeystroke()`** in `TypingBurstTracker.swift`: called on every keyDown from `cmux_sendEvent`. Must be zero-allocation (timestamp write + asyncAfter only). Do not add allocations, NotificationCenter posts on the hot path beyond the existing begin/end posts, or any I/O.
```

- [ ] **Step 3: Commit**

```bash
git add .claude/rules/pitfalls.md
git commit -m "docs: add TypingBurstTracker to pitfalls"
```
