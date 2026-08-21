import XCTest

final class HotkeyStateMachineTests: XCTestCase {

    private func machine() -> HotkeyStateMachine {
        var m = HotkeyStateMachine()
        m.holdThreshold = 0.4
        return m
    }

    func testQuickTapStartsAndKeepsRecording() {
        var m = machine()
        XCTAssertEqual(m.handle(.keyDown, now: 0), [.startRecording, .armHoldTimer(after: 0.4)])
        XCTAssertEqual(m.handle(.keyUp, now: 0.1), [.cancelHoldTimer, .enteredToggleMode])
        XCTAssertTrue(m.isRecording, "a tap leaves the recording running")
    }

    func testSecondTapStopsAndTranscribes() {
        var m = machine()
        _ = m.handle(.keyDown, now: 0)
        _ = m.handle(.keyUp, now: 0.1)
        XCTAssertEqual(m.handle(.keyDown, now: 3.0), [.stopAndTranscribe])
        // The release of that second tap must not start anything new.
        XCTAssertEqual(m.handle(.keyUp, now: 3.05), [])
        XCTAssertFalse(m.isRecording)
    }

    func testHoldRecordsUntilRelease() {
        var m = machine()
        _ = m.handle(.keyDown, now: 0)
        XCTAssertEqual(m.handle(.holdTimerFired, now: 0.4), [.enteredHoldMode])
        XCTAssertTrue(m.isRecording)
        XCTAssertEqual(m.handle(.keyUp, now: 2.5), [.stopAndTranscribe])
        XCTAssertFalse(m.isRecording)
    }

    func testLongPressWhoseTimerNeverFiredStillCountsAsHold() {
        var m = machine()
        _ = m.handle(.keyDown, now: 0)
        XCTAssertEqual(m.handle(.keyUp, now: 1.2), [.cancelHoldTimer, .stopAndTranscribe])
        XCTAssertFalse(m.isRecording)
    }

    func testKeyboardShortcutCancelsInsteadOfDictating() {
        var m = machine()
        _ = m.handle(.keyDown, now: 0)
        XCTAssertEqual(m.handle(.otherKeyDown, now: 0.05), [.cancelHoldTimer, .cancelRecording])
        XCTAssertFalse(m.isRecording)
        // Nothing else happens until the modifier is physically released.
        XCTAssertEqual(m.handle(.otherKeyDown, now: 0.1), [])
        XCTAssertEqual(m.handle(.keyUp, now: 0.4), [])
        XCTAssertEqual(m.state, .idle)
    }

    func testTypingDuringToggleRecordingIsIgnored() {
        var m = machine()
        _ = m.handle(.keyDown, now: 0)
        _ = m.handle(.keyUp, now: 0.1)
        XCTAssertEqual(m.handle(.otherKeyDown, now: 1.0), [], "typing mid-dictation must not cancel")
        XCTAssertTrue(m.isRecording)
    }

    func testMissedReleaseIsRescuedByResync() {
        var m = machine()
        _ = m.handle(.keyDown, now: 0)
        _ = m.handle(.holdTimerFired, now: 0.4)
        XCTAssertEqual(m.handle(.resyncKeyUp, now: 9.0), [.stopAndTranscribe])
        XCTAssertFalse(m.isRecording)
    }

    func testMaxDurationStopsBothGestures() {
        var m = machine()
        _ = m.handle(.keyDown, now: 0)
        _ = m.handle(.holdTimerFired, now: 0.4)
        XCTAssertEqual(m.handle(.maxDurationFired, now: 900), [.stopAndTranscribe])
        XCTAssertEqual(m.handle(.keyUp, now: 901), [], "the late release is swallowed")

        var toggle = machine()
        _ = toggle.handle(.keyDown, now: 0)
        _ = toggle.handle(.keyUp, now: 0.1)
        XCTAssertEqual(toggle.handle(.maxDurationFired, now: 900), [.stopAndTranscribe])
        XCTAssertFalse(toggle.isRecording)
    }

    func testAutoRepeatDownDoesNotRestart() {
        var m = machine()
        _ = m.handle(.keyDown, now: 0)
        XCTAssertEqual(m.handle(.keyDown, now: 0.2), [], "a repeat must not start a second recording")
    }

    func testStrayReleaseWhileIdleDoesNothing() {
        var m = machine()
        XCTAssertEqual(m.handle(.keyUp, now: 0), [])
        XCTAssertEqual(m.handle(.holdTimerFired, now: 0.1), [])
        XCTAssertEqual(m.state, .idle)
    }

    func testPressAgainBeforeReleaseIsSeenStartsFresh() {
        var m = machine()
        _ = m.handle(.keyDown, now: 0)
        _ = m.handle(.keyUp, now: 0.1)
        _ = m.handle(.keyDown, now: 1.0)   // stops; now draining
        XCTAssertEqual(
            m.handle(.keyDown, now: 1.05),
            [.startRecording, .armHoldTimer(after: 0.4)])
    }

    func testDoubleTapTogglesModeInsteadOfDictating() {
        var m = machine()
        _ = m.handle(.keyDown, now: 0)
        _ = m.handle(.keyUp, now: 0.1)      // first tap committed
        XCTAssertEqual(
            m.handle(.keyDown, now: 0.3),   // second tap, fast
            [.cancelRecording, .doubleTap],
            "two quick taps are the mode switch, and the blip recording is discarded")
        XCTAssertEqual(m.handle(.keyUp, now: 0.35), [], "its release is swallowed")
        XCTAssertEqual(m.state, .idle)
    }

    func testSlowSecondTapStillStopsNormally() {
        var m = machine()
        _ = m.handle(.keyDown, now: 0)
        _ = m.handle(.keyUp, now: 0.1)
        XCTAssertEqual(
            m.handle(.keyDown, now: 1.0),
            [.stopAndTranscribe],
            "a second tap after the double-tap window is an ordinary stop")
    }

    func testResetStopsAnythingInFlight() {
        var m = machine()
        _ = m.handle(.keyDown, now: 0)
        _ = m.handle(.keyUp, now: 0.1)
        XCTAssertEqual(m.reset(), [.cancelHoldTimer, .stopAndTranscribe])
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.reset(), [])
    }
}
