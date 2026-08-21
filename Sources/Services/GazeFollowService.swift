import CoreGraphics
import Foundation

/// The "look around" half of Gaze Mode.
///
/// Four times a second it checks where the pointer is. When it has settled
/// (dwell — you stopped moving, i.e. stopped scanning) over a window that is
/// not the current target, that window is acquired: raised as if clicked, its
/// nearest text box focused. While the pointer stays inside the same window,
/// nothing happens at all — no churn, no repeated raises.
///
/// The eye-tracker contract stays the same as everywhere else in Gaze Mode:
/// the pointer is the gaze.
final class GazeFollowService {

    /// Pointer must move less than this between two polls to count as settled.
    private let dwellTolerance: CGFloat = 14
    private let pollInterval = 0.25

    private let queue = DispatchQueue(label: "com.alexspitz.blurt.gaze.follow", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var lastPointer: CGPoint?
    /// Where the pointer was when the current target was acquired — moving
    /// well away from it (still inside the same window) means the user is now
    /// looking at a different box in that window.
    private var acquiredAt: CGPoint?

    private let lock = NSLock()
    private var current: GazeTargetService.Target?

    /// A new window/input was acquired. Fired off the main thread.
    var onTarget: (@Sendable (GazeTargetService.Target) -> Void)?

    var currentTarget: GazeTargetService.Target? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.lastPointer = CGEvent(source: nil)?.location
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + self.pollInterval, repeating: self.pollInterval)
            t.setEventHandler { [weak self] in self?.poll() }
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.lock.lock()
            self.current = nil
            self.lock.unlock()
        }
    }

    private func poll() {
        guard let pointer = CGEvent(source: nil)?.location else { return }
        let previous = lastPointer
        lastPointer = pointer

        // Still scanning — wait until the gaze settles somewhere.
        if let previous {
            let moved = hypot(pointer.x - previous.x, pointer.y - previous.y)
            guard moved < dwellTolerance else { return }
        }

        // What is actually on top here, by the window server's own ordering?
        // A stored rectangle is not enough — a large window behind others
        // would swallow every later look.
        guard let onTop = GazeTargetService.topWindow(at: pointer) else { return }

        lock.lock()
        let currentID = current?.windowID
        let currentInputFrame = current?.inputFrame
        lock.unlock()

        if let currentID, currentID == onTop.windowID {
            // Same window. Re-pick only if the gaze has clearly moved to a
            // different spot in it — a WhatsApp window has a search bar AND a
            // message bar, and which one you look at should be which one arms.
            guard let acquiredAt,
                  hypot(pointer.x - acquiredAt.x, pointer.y - acquiredAt.y) > 48
            else { return }
        }

        guard let target = GazeTargetService.acquireUnderPointer() else { return }
        acquiredAt = pointer

        // Same window, same box: nothing changed, tell nobody.
        if currentID == target.windowID, currentInputFrame == target.inputFrame {
            lock.lock()
            current = target
            lock.unlock()
            return
        }

        lock.lock()
        current = target
        lock.unlock()

        Log.info(
            "Gaze target: \(target.appName ?? "?")"
                + (target.foundInput ? " (input armed)" : " (window only)"))
        onTarget?(target)
    }
}
