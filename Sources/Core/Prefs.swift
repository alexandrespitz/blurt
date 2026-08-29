import Foundation

/// How long a WAV is kept once its transcript is safely in history.
enum AudioRetention: String, CaseIterable, Identifiable {
    case immediate
    case oneDay
    case sevenDays

    var id: String { rawValue }

    var label: String {
        switch self {
        case .immediate: return "Delete right after transcribing"
        case .oneDay: return "Keep for 1 day"
        case .sevenDays: return "Keep for 7 days"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .immediate: return nil
        case .oneDay: return 24 * 3600
        case .sevenDays: return 7 * 24 * 3600
        }
    }
}

/// Settings live in UserDefaults and are read from several threads (delivery
/// runs off the main thread), so reads go straight to `UserDefaults`, which is
/// thread-safe. `SettingsModel` is the SwiftUI-facing wrapper.
enum Prefs {

    enum Key {
        static let hotkeyID = "hotkeyID"
        static let autoPaste = "autoPaste"
        static let saveHistory = "saveHistory"
        static let retention = "audioRetention"
        static let didOnboard = "didCompleteOnboarding"
        static let launchAtLogin = "launchAtLogin"
        static let livePreview = "livePreview"
        static let playSounds = "playSounds"
        static let inputDeviceUID = "inputDeviceUID"
        static let languageHint = "languageHint"
        static let tidyEnabled = "tidyEnabled"
        static let copyAfterInsert = "copyAfterInsert"
        static let allowUnverifiedModel = "allowUnverifiedModel"
    }

    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.hotkeyID: HotkeySpec.default.id,
            Key.autoPaste: true,
            Key.saveHistory: true,
            Key.retention: AudioRetention.oneDay.rawValue,
            Key.didOnboard: false,
            Key.launchAtLogin: false,
            Key.livePreview: true,
            Key.playSounds: true,
            Key.tidyEnabled: false,
        ])
    }

    static var hotkey: HotkeySpec {
        get { HotkeySpec.withID(defaults.string(forKey: Key.hotkeyID)) }
        set { defaults.set(newValue.id, forKey: Key.hotkeyID) }
    }

    static var autoPaste: Bool {
        get { defaults.bool(forKey: Key.autoPaste) }
        set { defaults.set(newValue, forKey: Key.autoPaste) }
    }

    static var saveHistory: Bool {
        get { defaults.bool(forKey: Key.saveHistory) }
        set { defaults.set(newValue, forKey: Key.saveHistory) }
    }

    static var retention: AudioRetention {
        get { AudioRetention(rawValue: defaults.string(forKey: Key.retention) ?? "") ?? .oneDay }
        set { defaults.set(newValue.rawValue, forKey: Key.retention) }
    }

    static var didCompleteOnboarding: Bool {
        get { defaults.bool(forKey: Key.didOnboard) }
        set { defaults.set(newValue, forKey: Key.didOnboard) }
    }

    static var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    static var livePreview: Bool {
        get { defaults.bool(forKey: Key.livePreview) }
        set { defaults.set(newValue, forKey: Key.livePreview) }
    }

    static var playSounds: Bool {
        get { defaults.bool(forKey: Key.playSounds) }
        set { defaults.set(newValue, forKey: Key.playSounds) }
    }

    /// nil = whatever the system default input is.
    static var inputDeviceUID: String? {
        get { defaults.string(forKey: Key.inputDeviceUID) }
        set { defaults.set(newValue, forKey: Key.inputDeviceUID) }
    }

    /// ISO code ("fr") to pin the recognizer to one language; nil = auto-detect.
    static var languageHint: String? {
        get { defaults.string(forKey: Key.languageHint) }
        set { defaults.set(newValue, forKey: Key.languageHint) }
    }

    static var tidyEnabled: Bool {
        get { defaults.bool(forKey: Key.tidyEnabled) }
        set { defaults.set(newValue, forKey: Key.tidyEnabled) }
    }

    /// Whether direct gaze insertions should also land on the clipboard.
    /// Off by default: the point of insertion is that the words go only
    /// where you aimed them.
    /// Escape hatch for people who deliberately want to run a newer upstream
    /// model than this build pins. Off by default, and there is no UI for it:
    /// `defaults write com.alexspitz.blurt allowUnverifiedModel -bool true`.
    static var allowUnverifiedModel: Bool {
        defaults.bool(forKey: Key.allowUnverifiedModel)
    }

    static var copyAfterInsert: Bool {
        get { defaults.bool(forKey: Key.copyAfterInsert) }
        set { defaults.set(newValue, forKey: Key.copyAfterInsert) }
    }
}
