import Foundation

/// A key you can dictate with.
///
/// Modifier keys are identified by their device-dependent flag bit rather than
/// the generic mask, which is the only reliable way to tell right Option from
/// left Option. Modifiers are deliberately **not** swallowed: a bare modifier
/// press means nothing to other apps, and passing it through keeps Option-as-
/// AltGr typing (French/AZERTY) completely untouched.
struct HotkeySpec: Equatable, Hashable {

    let id: String
    let displayName: String
    let symbol: String
    /// Virtual keycode as reported in the event's keycode field.
    let keyCode: Int64
    /// Device-dependent modifier bit; 0 for ordinary keys.
    let deviceMask: UInt64
    let note: String?

    var isModifier: Bool { deviceMask != 0 }
    /// Ordinary keys get consumed so they never reach the focused app.
    var shouldSwallow: Bool { !isModifier }

    // Device-dependent modifier bits (IOKit/NX_*). Not in the public CGEventFlags API.
    private static let rightCommandBit: UInt64 = 0x0000_0010
    private static let rightOptionBit: UInt64 = 0x0000_0040
    private static let rightControlBit: UInt64 = 0x0000_2000
    private static let rightShiftBit: UInt64 = 0x0000_0004
    private static let fnBit: UInt64 = 0x0080_0000

    static let rightOption = HotkeySpec(
        id: "rightOption", displayName: "Right Option", symbol: "⌥",
        keyCode: 61, deviceMask: rightOptionBit,
        note: "On French/AZERTY layouts this key also types AltGr characters. "
            + "Blurt passes it through, so typing still works, but the mic "
            + "briefly turns on. Pick Fn or F13 if that bothers you.")

    static let rightCommand = HotkeySpec(
        id: "rightCommand", displayName: "Right Command", symbol: "⌘",
        keyCode: 54, deviceMask: rightCommandBit, note: nil)

    static let rightControl = HotkeySpec(
        id: "rightControl", displayName: "Right Control", symbol: "⌃",
        keyCode: 62, deviceMask: rightControlBit, note: nil)

    static let rightShift = HotkeySpec(
        id: "rightShift", displayName: "Right Shift", symbol: "⇧",
        keyCode: 60, deviceMask: rightShiftBit, note: nil)

    static let fn = HotkeySpec(
        id: "fn", displayName: "Fn / Globe", symbol: "🌐",
        keyCode: 63, deviceMask: fnBit,
        note: "Set System Settings → Keyboard → “Press 🌐 key to” = Do Nothing, "
            + "otherwise macOS also opens the emoji picker or its own dictation.")

    static let f13 = HotkeySpec(id: "f13", displayName: "F13", symbol: "F13", keyCode: 105, deviceMask: 0, note: nil)
    static let f14 = HotkeySpec(id: "f14", displayName: "F14", symbol: "F14", keyCode: 107, deviceMask: 0, note: nil)
    static let f15 = HotkeySpec(id: "f15", displayName: "F15", symbol: "F15", keyCode: 113, deviceMask: 0, note: nil)
    static let f16 = HotkeySpec(id: "f16", displayName: "F16", symbol: "F16", keyCode: 106, deviceMask: 0, note: nil)
    static let f17 = HotkeySpec(id: "f17", displayName: "F17", symbol: "F17", keyCode: 64, deviceMask: 0, note: nil)
    static let f18 = HotkeySpec(id: "f18", displayName: "F18", symbol: "F18", keyCode: 79, deviceMask: 0, note: nil)
    static let f19 = HotkeySpec(id: "f19", displayName: "F19", symbol: "F19", keyCode: 80, deviceMask: 0, note: nil)

    static let f5 = HotkeySpec(
        id: "f5", displayName: "F5", symbol: "F5", keyCode: 96, deviceMask: 0,
        note: "Needs “Use F1, F2, etc. keys as standard function keys” turned on, "
            + "or you have to hold Fn as well.")
    static let f6 = HotkeySpec(
        id: "f6", displayName: "F6", symbol: "F6", keyCode: 97, deviceMask: 0,
        note: "Needs “Use F1, F2, etc. keys as standard function keys” turned on, "
            + "or you have to hold Fn as well.")

    static let all: [HotkeySpec] = [
        .rightOption, .rightCommand, .rightControl, .rightShift, .fn,
        .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f5, .f6,
    ]

    static let `default` = HotkeySpec.rightOption

    static func withID(_ id: String?) -> HotkeySpec {
        guard let id else { return .default }
        return all.first { $0.id == id } ?? .default
    }
}
