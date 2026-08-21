import SwiftUI

struct MenuBarView: View {

    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Text(coordinator.statusLine)

        Divider()

        Button(coordinator.isRecording ? "Stop Dictation" : "Start Dictation") {
            coordinator.toggleDictation()
        }
        .disabled(!coordinator.modelState.isReady || !coordinator.permissions.readyToDictate)

        Toggle("Gaze Mode — look, talk, done", isOn: $coordinator.gazeMode)

        if !coordinator.pending.isEmpty || !coordinator.quarantined.isEmpty {
            Button("\(coordinator.pending.count + coordinator.quarantined.count) recording(s) need attention…") {
                DashboardWindowController.shared.show()
            }
        }

        if let latest = coordinator.history.first {
            Button("Copy Last Transcript") {
                coordinator.copyToClipboard(latest.text)
            }
        }

        Divider()

        Button("Open Dashboard…") {
            DashboardWindowController.shared.show()
        }

        Divider()

        Button("Quit Blurt") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
