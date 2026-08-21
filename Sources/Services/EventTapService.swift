import AppKit
import Foundation

/// Watches the keyboard for the dictation key.
///
/// The tap lives on its own thread with its own run loop. That is deliberate:
/// macOS disables an active event tap whose callback stalls, and the whole
/// point of this app is that a busy or wedged UI cannot cost you a dictation.
///
/// Modifier hotkeys are observed but never swallowed — a bare Option press
/// means nothing to other apps, and letting it through keeps AltGr typing on
/// French layouts working exactly as before. Ordinary keys (F13 and friends)
/// are swallowed so they do not also reach the focused app.
final class EventTapService {

    /// Stamped onto the keystrokes we synthesize for pasting so we can
    /// recognise and ignore our own events.
    static let syntheticEventMarker: Int64 = 0x5041_524B  // "PARK"

    enum Status: Equatable {
        case stopped
        case running
        case notPermitted
    }

    private let lock = NSRecursiveLock()
    private var machine = HotkeyStateMachine()
    private var spec: HotkeySpec = .default
    private var pendingSpec: HotkeySpec?

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var machPort: CFMachPort?
    private var source: CFRunLoopSource?

    private let timerQueue = DispatchQueue(label: "com.alexspitz.blurt.hotkey.timers")
    private var holdTimer: DispatchSourceTimer?
    private var maxTimer: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?

    private var _status: Status = .stopped

    /// Emitted for every command the state machine produces, off the main thread.
    var onCommand: (@Sendable (HotkeyStateMachine.Command) -> Void)?
    var onStatusChange: (@Sendable (Status) -> Void)?

    var status: Status {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    var currentSpec: HotkeySpec {
        lock.lock(); defer { lock.unlock() }
        return spec
    }

    // MARK: - Lifecycle

    func start(spec: HotkeySpec) {
        lock.lock()
        self.spec = spec
        guard thread == nil else {
            lock.unlock()
            return
        }
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "com.alexspitz.blurt.eventtap"
        t.qualityOfService = .userInteractive
        thread = t
        lock.unlock()
        t.start()
    }

    func stop() {
        cancelTimers()
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        thread = nil
        setStatus(.stopped)
    }

    /// Applies a new hotkey. Deferred if a recording is in progress, so the key
    /// cannot change out from under a dictation.
    func updateSpec(_ new: HotkeySpec) {
        lock.lock()
        if machine.isRecording {
            pendingSpec = new
            lock.unlock()
            return
        }
        spec = new
        pendingSpec = nil
        _ = machine.reset()
        lock.unlock()
        Log.info("Dictation key is now \(new.displayName)")
    }

    private func threadMain() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<EventTapService>.fromOpaque(refcon).takeUnretainedValue()
                return service.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon)
        else {
            Log.error("Could not create the keyboard tap — Accessibility permission is missing")
            // Clear the dead thread's handle, or the retry that fires when the
            // permission is granted would see a "running" thread and give up —
            // which is exactly why granting used to require an app restart.
            lock.lock()
            thread = nil
            lock.unlock()
            setStatus(.notPermitted)
            return
        }

        machPort = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        source = src
        runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        setStatus(.running)
        startWatchdog()
        Log.info("Keyboard tap running on its own thread")

        CFRunLoopRun()

        // Only reached when someone stops the run loop.
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        machPort = nil
        source = nil
        runLoop = nil
        lock.lock()
        thread = nil
        lock.unlock()
    }

    private func setStatus(_ new: Status) {
        lock.lock()
        let changed = _status != new
        _status = new
        lock.unlock()
        if changed { onStatusChange?(new) }
    }

    // MARK: - The tap callback

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap it thinks is misbehaving. Turn it straight back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            Log.info("Keyboard tap was disabled by the system — re-enabled")
            resyncKeyState()
            return Unmanaged.passUnretained(event)
        }

        // Never react to the ⌘V we synthesize ourselves.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let spec = self.spec
        lock.unlock()

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        var swallow = false

        switch type {
        case .flagsChanged:
            guard spec.isModifier else { break }
            if keyCode == spec.keyCode {
                let isDown = (event.flags.rawValue & spec.deviceMask) != 0
                feed(isDown ? .keyDown : .keyUp)
                // Modifiers pass through untouched, on purpose.
            }

        case .keyDown:
            // Auto-repeat would otherwise look like a stream of fresh presses.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { break }
            if !spec.isModifier && keyCode == spec.keyCode {
                feed(.keyDown)
                swallow = spec.shouldSwallow
            } else {
                feed(.otherKeyDown)
            }

        case .keyUp:
            if !spec.isModifier && keyCode == spec.keyCode {
                feed(.keyUp)
                swallow = spec.shouldSwallow
            }

        default:
            break
        }

        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    // MARK: - Driving the state machine

    private func feed(_ event: HotkeyStateMachine.Event) {
        lock.lock()
        let commands = machine.handle(event, now: CFAbsoluteTimeGetCurrent())
        let idleNow = !machine.isRecording && machine.state == .idle
        let deferred = pendingSpec
        if idleNow, let deferred {
            spec = deferred
            pendingSpec = nil
            Log.info("Dictation key is now \(deferred.displayName)")
        }
        lock.unlock()

        for command in commands {
            switch command {
            case .armHoldTimer(let after):
                armHoldTimer(after: after)
            case .cancelHoldTimer:
                cancelHoldTimer()
            case .startRecording:
                armMaxTimer()
                onCommand?(command)
            case .stopAndTranscribe, .cancelRecording:
                cancelMaxTimer()
                onCommand?(command)
            default:
                onCommand?(command)
            }
        }
    }

    private func armHoldTimer(after seconds: Double) {
        cancelHoldTimer()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            self?.cancelHoldTimer()
            self?.feed(.holdTimerFired)
        }
        holdTimer = timer
        timer.resume()
    }

    private func cancelHoldTimer() {
        holdTimer?.cancel()
        holdTimer = nil
    }

    private func armMaxTimer() {
        cancelMaxTimer()
        lock.lock()
        let limit = machine.maxRecordingDuration
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + limit)
        timer.setEventHandler { [weak self] in
            self?.cancelMaxTimer()
            self?.feed(.maxDurationFired)
        }
        maxTimer = timer
        timer.resume()
    }

    private func cancelMaxTimer() {
        maxTimer?.cancel()
        maxTimer = nil
    }

    private func cancelTimers() {
        cancelHoldTimer()
        cancelMaxTimer()
        watchdog?.cancel()
        watchdog = nil
    }

    /// Belt and braces: keeps the tap alive, and rescues the state machine if a
    /// key-up was ever missed (which would otherwise record forever).
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let port = self.machPort, !CGEvent.tapIsEnabled(tap: port) {
                CGEvent.tapEnable(tap: port, enable: true)
                Log.info("Watchdog re-enabled the keyboard tap")
            }
            self.resyncKeyState()
        }
        watchdog = timer
        timer.resume()
    }

    private func resyncKeyState() {
        lock.lock()
        let believesDown = machine.isRecording
        let spec = self.spec
        lock.unlock()
        guard believesDown else { return }

        let physicallyDown: Bool
        if spec.isModifier {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            physicallyDown = (flags.rawValue & spec.deviceMask) != 0
        } else {
            physicallyDown = CGEventSource.keyState(
                .combinedSessionState, key: CGKeyCode(spec.keyCode))
        }

        // In toggle mode the key is legitimately up while recording continues.
        lock.lock()
        let inHoldGesture: Bool
        switch machine.state {
        case .pressPending, .recordingHold: inHoldGesture = true
        default: inHoldGesture = false
        }
        lock.unlock()

        if inHoldGesture && !physicallyDown {
            Log.info("Watchdog noticed a missed key release — stopping the recording")
            feed(.resyncKeyUp)
        }
    }
}
