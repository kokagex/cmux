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
    /// Use `isBurstingUnchecked` for non-isolated access from main-thread code
    /// that the compiler cannot prove is on main actor.
    private(set) var isBursting: Bool = false

    /// Read `isBursting` from non-isolated contexts that run on the main thread
    /// (e.g. `NotificationBurstCoalescer.tryFlush()`, `PortScanner.kick()`).
    /// Callers must ensure they are on the main thread.
    nonisolated var isBurstingUnchecked: Bool {
        MainActor.assumeIsolated { isBursting }
    }

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
