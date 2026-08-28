import ApplicationServices
import Foundation

/// Live preview *inside* the target text box, for apps whose accessibility
/// supports it.
///
/// Mechanism: insert the partial text at the caret, remember the range it
/// occupies, and on every update select that range and replace it — so the
/// text in the box grows and self-corrects as the model re-hears, and the
/// final transcript takes the same path. Apps that cannot do range surgery
/// (many Electron apps) fail the capability check and get the docked pill
/// overlay instead. If range surgery starts failing mid-utterance, the
/// session marks itself broken and the final delivery repairs the box by
/// replacing whatever it managed to insert.
final class InBoxPreview {

    private let input: AXUIElement
    private var location: Int
    private var length = 0
    private var broken = false
    /// What we last wrote — checked before every replacement so a user who
    /// typed into the box meanwhile never has their words clobbered.
    private var lastWritten = ""

    private init(input: AXUIElement, location: Int) {
        self.input = input
        self.location = location
    }

    /// Starts a session if the field supports range surgery and its caret can
    /// be read. Returns nil otherwise — the caller falls back to the overlay.
    static func begin(in input: AXUIElement) -> InBoxPreview? {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            input, kAXSelectedTextAttribute as CFString, &settable) == .success,
            settable.boolValue
        else { return nil }
        guard AXUIElementIsAttributeSettable(
            input, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
            settable.boolValue
        else { return nil }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            input, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
            let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }

        var range = CFRange()
        guard AXValueGetValue(
            unsafeBitCast(rangeValue, to: AXValue.self), .cfRange, &range)
        else { return nil }

        // Whatever was selected will be replaced by the dictation — the same
        // thing typing over a selection does.
        return InBoxPreview(input: input, location: range.location)
    }

    /// Replaces the previously shown partial with a newer one.
    /// Returns false once the field stops cooperating.
    @discardableResult
    func update(_ text: String) -> Bool {
        guard !broken else { return false }
        guard replaceTrackedRange(with: text) else {
            broken = true
            return false
        }
        return true
    }

    /// Final text in, session over. Returns true when the box ended up
    /// containing exactly the final transcript via this path.
    func finish(_ finalText: String) -> Bool {
        guard !broken else { return false }
        let ok = replaceTrackedRange(with: finalText)
        broken = true  // no further use either way
        return ok
    }

    private func replaceTrackedRange(with text: String) -> Bool {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return false }
        guard AXUIElementSetAttributeValue(
            input, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success
        else { return false }

        // The range we are about to overwrite must still contain exactly what
        // we wrote last time. If it does not — the user typed in the box, the
        // app reflowed it — stop touching their text.
        if length > 0 {
            var selectedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                input, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
                let selected = selectedRef as? String,
                selected == lastWritten
            else { return false }
        }

        guard AXUIElementSetAttributeValue(
            input, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        lastWritten = text
        // AX ranges count UTF-16 units, like NSString.
        length = (text as NSString).length

        // Park the caret at the end of what we wrote, so a user click-and-type
        // lands somewhere sensible.
        var caret = CFRange(location: location + length, length: 0)
        if let caretValue = AXValueCreate(.cfRange, &caret) {
            AXUIElementSetAttributeValue(
                input, kAXSelectedTextRangeAttribute as CFString, caretValue)
        }
        return true
    }
}
