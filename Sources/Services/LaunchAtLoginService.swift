import Foundation
import ServiceManagement

/// Start-at-login, via the modern API. Registration records the app's current
/// path, so it wants Blurt to be living in /Applications.
enum LaunchAtLoginService {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            Prefs.launchAtLogin = enabled
        } catch {
            Log.error("Could not change the login item: \(error.localizedDescription)")
        }
    }
}
