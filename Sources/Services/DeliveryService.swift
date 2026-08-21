import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Puts the finished transcript where you were typing.
///
/// Two guards stand between the transcript and the keystrokes:
/// the app you dictated into must still be the one in front, and the focused
/// field must not be a secure one. Fail either and we copy only — a dictation
/// pasted into the wrong window is worse than one you paste yourself.
enum DeliveryService {

    struct Target: Equatable {
        var bundleID: String?
        var pid: Int32?
        var name: String?

        static func current() -> Target {
            let app = NSWorkspace.shared.frontmostApplication
            return Target(
                bundleID: app?.bundleIdentifier,
                pid: app?.processIdentifier,
                name: app?.localizedName)
        }
    }

    enum Result: Equatable {
        case pasted(appName: String?)
        case copiedOnly(reason: String)
    }

    /// Clipboard only — used when the text was already delivered another way.
    static func copyOnly(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Writes the transcript to the clipboard and, when it is safe to do so,
    /// pastes it into the frontmost app.
    @discardableResult
    static func deliver(text: String, intendedTarget: Target?, allowPaste: Bool) -> Result {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard allowPaste else {
            return .copiedOnly(reason: "auto-paste is switched off")
        }
        guard AXIsProcessTrusted() else {
            return .copiedOnly(reason: "Blurt does not have Accessibility permission")
        }
        if IsSecureEventInputEnabled() {
            return .copiedOnly(reason: "a password field is active")
        }
        if focusedFieldIsSecure() {
            return .copiedOnly(reason: "the focused field is a secure one")
        }

        let now = Target.current()
        if let intended = intendedTarget, let wanted = intended.bundleID,
           let actual = now.bundleID, wanted != actual {
            return .copiedOnly(reason: "you switched to \(now.name ?? actual)")
        }

        paste()
        return .pasted(appName: now.name)
    }

    /// Synthesizes ⌘V. Tagged so our own keyboard tap ignores it.
    private static func paste() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: EventTapService.syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: EventTapService.syntheticEventMarker)

        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
    }

    /// Asks the accessibility API whether the field with keyboard focus is a
    /// password-style field. `IsSecureEventInputEnabled` alone misses fields
    /// that do not turn on secure input.
    private static func focusedFieldIsSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let element = focused
        else { return false }

        guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        let axElement = unsafeBitCast(element, to: AXUIElement.self)

        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axElement, kAXSubroleAttribute as CFString, &subrole) == .success,
            let value = subrole as? String
        else { return false }

        return value == "AXSecureTextField"
    }
}
