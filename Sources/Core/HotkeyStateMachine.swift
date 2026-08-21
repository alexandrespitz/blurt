import Foundation

/// One key, two gestures: a quick tap starts recording and the next tap stops
/// it; holding the key records only while it is held.
///
/// Recording starts on key **down** in both cases, before we know which gesture
/// it will turn out to be, so the first syllable is never clipped. The hold
/// timer decides afterwards which way to interpret the release.
///
/// Pure and synchronous — no clock of its own, no I/O. The caller supplies
/// `now`, which makes every transition here directly testable.
struct HotkeyStateMachine {

    enum State: Equatable {
        case idle
        /// Key is down, gesture not yet known. Recording has already started.
        case pressPending(since: Double)
        /// Tap gesture committed: recording continues after the release.
        /// `since` timestamps the commit — a second tap right after it is a
        /// double-tap, which means "toggle Gaze Mode", not "stop".
        case recordingToggle(since: Double)
        /// Hold gesture: recording ends when the key comes up.
        case recordingHold
        /// The user pressed another key while ours was down — they meant a
        /// keyboard shortcut, not dictation. Stay out of the way until release.
        case comboPassthrough
        /// Recording already stopped; swallow the key-up that is still coming.
        case drainingRelease
    }

    enum Event: Equatable {
        case keyDown
        case keyUp
        /// Any other key went down while ours was held.
        case otherKeyDown
        case holdTimerFired
        case maxDurationFired
        /// The watchdog noticed the key is physically up though we think it is down.
        case resyncKeyUp
    }

    enum Command: Equatable {
        case startRecording
        case cancelRecording
        case stopAndTranscribe
        case armHoldTimer(after: Double)
        case cancelHoldTimer
        /// UI hint only: the gesture resolved to a tap-to-toggle.
        case enteredToggleMode
        /// UI hint only: the gesture resolved to push-to-talk.
        case enteredHoldMode
        /// Two quick taps: the Gaze Mode switch.
        case doubleTap
    }

    /// Longer than this and the press counts as "holding", not "tapping".
    var holdThreshold: Double = 0.4
    /// A second tap within this window of the first is a double-tap.
    var doubleTapWindow: Double = 0.35
    /// Hard stop so a wedged key can never record forever.
    var maxRecordingDuration: Double = 900

    private(set) var state: State = .idle

    var isRecording: Bool {
        switch state {
        case .recordingToggle, .recordingHold, .pressPending: return true
        default: return false
        }
    }

    mutating func handle(_ event: Event, now: Double) -> [Command] {
        switch (state, event) {

        // MARK: idle
        case (.idle, .keyDown):
            state = .pressPending(since: now)
            return [.startRecording, .armHoldTimer(after: holdThreshold)]

        case (.idle, _):
            return []  // stray release or late timer

        // MARK: press pending — gesture still ambiguous
        case (.pressPending(let since), .keyUp):
            if now - since < holdThreshold {
                state = .recordingToggle(since: now)
                return [.cancelHoldTimer, .enteredToggleMode]
            }
            // The timer has not fired yet but this was clearly a hold.
            state = .idle
            return [.cancelHoldTimer, .stopAndTranscribe]

        case (.pressPending, .holdTimerFired):
            state = .recordingHold
            return [.enteredHoldMode]

        case (.pressPending, .otherKeyDown):
            // A shortcut, not dictation. Throw the fragment away.
            state = .comboPassthrough
            return [.cancelHoldTimer, .cancelRecording]

        case (.pressPending, .resyncKeyUp):
            state = .idle
            return [.cancelHoldTimer, .stopAndTranscribe]

        case (.pressPending, .maxDurationFired):
            state = .drainingRelease
            return [.cancelHoldTimer, .stopAndTranscribe]

        case (.pressPending, .keyDown):
            return []  // auto-repeat that slipped through

        // MARK: push-to-talk
        case (.recordingHold, .keyUp), (.recordingHold, .resyncKeyUp):
            state = .idle
            return [.stopAndTranscribe]

        case (.recordingHold, .maxDurationFired):
            state = .drainingRelease
            return [.stopAndTranscribe]

        case (.recordingHold, _):
            return []

        // MARK: tap-to-toggle
        case (.recordingToggle(let since), .keyDown):
            if now - since < doubleTapWindow {
                // Two quick taps: not a dictation at all — the mode switch.
                state = .drainingRelease
                return [.cancelRecording, .doubleTap]
            }
            state = .drainingRelease
            return [.stopAndTranscribe]

        case (.recordingToggle, .maxDurationFired):
            state = .idle
            return [.stopAndTranscribe]

        case (.recordingToggle, _):
            // Other keys pass through freely — the user is mid-dictation and may
            // well be using the computer.
            return []

        // MARK: combo passthrough
        case (.comboPassthrough, .keyUp), (.comboPassthrough, .resyncKeyUp):
            state = .idle
            return []

        case (.comboPassthrough, _):
            return []

        // MARK: draining
        case (.drainingRelease, .keyUp), (.drainingRelease, .resyncKeyUp):
            state = .idle
            return []

        case (.drainingRelease, .keyDown):
            // Released and pressed again faster than we saw the release.
            state = .pressPending(since: now)
            return [.startRecording, .armHoldTimer(after: holdThreshold)]

        case (.drainingRelease, _):
            return []
        }
    }

    /// Forces the machine back to rest, e.g. when the hotkey is reconfigured or
    /// the tap is rebuilt.
    mutating func reset() -> [Command] {
        let wasRecording = isRecording
        state = .idle
        return wasRecording ? [.cancelHoldTimer, .stopAndTranscribe] : []
    }
}
