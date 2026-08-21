import AppKit
import ApplicationServices
import Foundation

/// Gaze Mode's aiming system: whatever is under the pointer is what you are
/// looking at.
///
/// The eye-tracking half is deliberately not in this app — any tool that moves
/// the pointer to where you look (like the one the principal already built)
/// plugs in for free, and with no eye tracker at all the mode still works as
/// "dictate to what I'm pointing at, without clicking".
///
/// Acquisition does three things, in order: find the window under the pointer,
/// bring it forward exactly as a click would, and focus the nearest text input
/// in it. Everything runs off the main thread; the audio pipeline never waits.
enum GazeTargetService {

    struct Target {
        var appName: String?
        var bundleID: String?
        var pid: pid_t
        /// The chosen input's frame, in Cocoa (bottom-left) screen coordinates,
        /// for docking the preview pill next to it.
        var inputFrame: CGRect?
        var foundInput: Bool
        /// The focused input element itself — lets a finished transcript be
        /// inserted into this exact box later, even if focus moved on.
        var input: AXUIElement?
        /// The window's frame in top-left global coordinates, so the follow
        /// loop can tell "still looking at the same window" without asking
        /// the accessibility system again.
        var windowFrameTopLeft: CGRect?
        /// The window server's stable identifier for the target window — the
        /// follow loop's identity check. Accessibility-element equality proved
        /// unreliable; window numbers are not.
        var windowID: CGWindowID?
    }

    /// What the user actually sees at this point, from the window server's
    /// real front-to-back order. Skips invisible overlay windows (alpha ~0,
    /// non-normal layers) that accessibility hit-testing happily lands on —
    /// which is how a hidden Zoom overlay once swallowed the whole screen.
    static func topWindow(at point: CGPoint) -> (pid: pid_t, windowID: CGWindowID, bounds: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        let ourPID = ProcessInfo.processInfo.processIdentifier
        for info in list {  // already ordered front to back
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.05,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ourPID,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let raw = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = raw["X"], let y = raw["Y"],
                  let width = raw["Width"], let height = raw["Height"]
            else { continue }

            let bounds = CGRect(x: x, y: y, width: width, height: height)
            // Menu-bar stubs and one-pixel slivers are not dictation targets.
            guard bounds.width >= 60, bounds.height >= 40 else { continue }
            if bounds.contains(point) {
                return (pid, CGWindowID(number), bounds)
            }
        }
        return nil
    }

    private static let inputRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
    ]

    /// How many elements the input search will visit before giving up. Keeps a
    /// pathological accessibility tree from stalling acquisition.
    private static let searchBudget = 350

    /// Finds, raises and focuses what is under the pointer right now.
    /// Returns nil when there is nothing sensible there (our own HUD, the
    /// desktop, a window that refuses accessibility).
    static func acquireUnderPointer() -> Target? {
        guard let pointerEvent = CGEvent(source: nil) else { return nil }
        let point = pointerEvent.location  // top-left-origin global coordinates

        // The window server decides what "under the pointer" means — it knows
        // the true stacking order and we can skip invisible overlays.
        guard let top = topWindow(at: point) else { return nil }
        let pid = top.pid
        let app = NSRunningApplication(processIdentifier: pid)

        // Hit-test scoped to that app, so overlays from other apps cannot
        // intercept. Fall back to matching the app's windows by frame.
        let appElement = AXUIElementCreateApplication(pid)
        var hitRef: AXUIElement?
        AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &hitRef)

        var window: AXUIElement?
        if let element = hitRef {
            window = enclosingWindow(of: element)
        }
        if window == nil {
            window = windowMatching(bounds: top.bounds, inApp: appElement)
        }
        guard let window else { return nil }
        let element = hitRef ?? window

        // Deliberately passive: no raising, no activating, no reordering.
        // Gaze Mode switches which visible thing is armed — like glancing at a
        // window that is already in front of you, not like dredging one up
        // from behind. Delivery goes through accessibility, which does not
        // need the app to be frontmost.
        //
        // Electron apps (ChatGPT, Slack, WhatsApp…) keep their accessibility
        // tree dormant until someone declares themselves assistive. Harmless
        // for everything else.
        AXUIElementSetAttributeValue(
            appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        // The element under the pointer might itself be the input…
        var input: AXUIElement?
        if let role = stringAttribute(element, kAXRoleAttribute),
           inputRoles.contains(role),
           stringAttribute(element, kAXSubroleAttribute) != "AXSecureTextField"
        {
            input = element
        } else {
            // …otherwise look through the window for the nearest one.
            input = nearestInput(in: window, to: point)
        }

        var inputFrame: CGRect?
        if let input {
            AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if let frame = frame(of: input) {
                inputFrame = cocoaRect(fromTopLeft: frame)
            }
        }

        return Target(
            appName: app?.localizedName,
            bundleID: app?.bundleIdentifier,
            pid: pid,
            inputFrame: inputFrame,
            foundInput: input != nil,
            input: input,
            windowFrameTopLeft: frame(of: window),
            windowID: top.windowID)
    }

    /// Finds the app's accessibility window whose frame matches the window
    /// server's bounds — the fallback when the scoped hit-test comes up empty.
    private static func windowMatching(bounds: CGRect, inApp app: AXUIElement) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
            let windows = windowsRef as? [AnyObject]
        else { return nil }

        for candidate in windows where CFGetTypeID(candidate) == AXUIElementGetTypeID() {
            let window = unsafeBitCast(candidate, to: AXUIElement.self)
            guard let windowFrame = frame(of: window) else { continue }
            let dx = abs(windowFrame.origin.x - bounds.origin.x)
            let dy = abs(windowFrame.origin.y - bounds.origin.y)
            let dw = abs(windowFrame.width - bounds.width)
            if dx < 8 && dy < 8 && dw < 16 { return window }
        }
        return nil
    }

    /// Inserts text at the caret of a previously captured input element —
    /// without needing that app to be frontmost. This is what lets you look at
    /// the next window while the last sentence is still being transcribed.
    static func insert(text: String, into input: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            input, kAXSelectedTextAttribute as CFString, &settable) == .success,
            settable.boolValue
        else { return false }
        return AXUIElementSetAttributeValue(
            input, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    // MARK: - Tree walking

    private static func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        // The element often carries its window directly.
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef)
            == .success,
            let window = windowRef, CFGetTypeID(window) == AXUIElementGetTypeID()
        {
            return unsafeBitCast(window, to: AXUIElement.self)
        }

        // Otherwise climb until a window role appears.
        var current = element
        for _ in 0..<12 {
            if stringAttribute(current, kAXRoleAttribute) == "AXWindow" { return current }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                current, kAXParentAttribute as CFString, &parentRef) == .success,
                let parent = parentRef, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return nil }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return nil
    }

    /// Breadth-first search of the window for text inputs, then the geometric
    /// pick. The budget keeps worst-case trees (browsers) from stalling.
    private static func nearestInput(in window: AXUIElement, to point: CGPoint) -> AXUIElement? {
        var queue: [AXUIElement] = [window]
        var visited = 0
        var found: [(element: AXUIElement, frame: CGRect)] = []

        while !queue.isEmpty && visited < searchBudget {
            let current = queue.removeFirst()
            visited += 1

            if let role = stringAttribute(current, kAXRoleAttribute),
               inputRoles.contains(role),
               stringAttribute(current, kAXSubroleAttribute) != "AXSecureTextField",
               let frame = frame(of: current)
            {
                found.append((current, frame))
                continue  // inputs rarely nest other inputs
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                current, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AnyObject]
            {
                for child in children where CFGetTypeID(child) == AXUIElementGetTypeID() {
                    queue.append(unsafeBitCast(child, to: AXUIElement.self))
                }
            }
        }

        let candidates = found.enumerated().map {
            NearestInput.Candidate(index: $0.offset, frame: $0.element.frame)
        }
        guard let picked = NearestInput.pick(candidates, near: point) else { return nil }
        return found[picked.index].element
    }

    // MARK: - Attribute plumbing

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    /// The element's frame in top-left-origin global coordinates.
    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXPositionAttribute as CFString, &positionRef) == .success,
            AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = positionRef, let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(
                unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
        else { return nil }

        return CGRect(origin: position, size: size)
    }

    /// Top-left-origin global rect → Cocoa bottom-left-origin rect.
    private static func cocoaRect(fromTopLeft rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height)
    }
}
