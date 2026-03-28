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
