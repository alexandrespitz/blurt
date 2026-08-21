import AppKit
import SwiftUI

@main
struct BlurtApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var coordinator = AppCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: coordinator)
        } label: {
            Image(systemName: coordinator.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Startup order matters: take the single-instance lock before anything touches
/// the recordings directory, because holding that lock for the whole session is
/// what lets recovery treat "still in inflight/" as "abandoned".
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let instanceGuard = SingleInstanceGuard()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceGuard.acquire() else {
            let alert = NSAlert()
            alert.messageText = "Blurt is already running"
            alert.informativeText =
                "Look for the microphone icon in the menu bar. If it is not there, "
                + "force-quit the other copy and open Blurt again."
            alert.alertStyle = .warning
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        MainActor.assumeIsolated {
            let coordinator = AppCoordinator.shared
            coordinator.start()
            if !coordinator.didCompleteOnboarding {
                DashboardWindowController.shared.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppCoordinator.shared.shutdown()
        }
        instanceGuard.release()
    }
}

/// The dashboard is a hand-managed window rather than a SwiftUI `Window` scene:
/// a menu bar app needs to open it from places SwiftUI's scene plumbing cannot
/// reach, such as launch-time onboarding.
@MainActor
final class DashboardWindowController {

    static let shared = DashboardWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            AppCoordinator.shared.refreshPending()
            return
        }

        let hosting = NSHostingController(
            rootView: DashboardView(coordinator: AppCoordinator.shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Blurt"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 600))
        window.center()

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        AppCoordinator.shared.refreshPending()
    }
}
