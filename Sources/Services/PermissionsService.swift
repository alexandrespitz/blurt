import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

/// The three system permissions Blurt may need, and the shortest path to
/// granting each one.
final class PermissionsService {

    enum Access: Equatable {
        case granted
        case denied
        case notDetermined

        var isGranted: Bool { self == .granted }
    }

    struct Snapshot: Equatable {
        var microphone: Access
        var accessibility: Access
        var inputMonitoring: Access

        /// Input Monitoring is only reported as a blocker if the system actually
        /// withholds it; on most Macs an active tap needs Accessibility alone.
        var readyToDictate: Bool {
            microphone.isGranted && accessibility.isGranted
        }
    }

    /// Polled while the dashboard is open so a grant shows up without a restart.
    private var timer: DispatchSourceTimer?
    private var last: Snapshot?

    var onChange: (@Sendable (Snapshot) -> Void)?

    func snapshot() -> Snapshot {
        Snapshot(
            microphone: microphoneAccess(),
            accessibility: AXIsProcessTrusted() ? .granted : .denied,
            inputMonitoring: inputMonitoringAccess())
    }

    func microphoneAccess() -> Access {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func inputMonitoringAccess() -> Access {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeUnknown: return .notDetermined
        default: return .denied
        }
    }

    func requestMicrophone(_ completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted)
        }
    }

    /// Shows the system's own Accessibility prompt, which offers to open the
    /// right settings pane.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    func openSettings(_ pane: Pane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }

    func startPolling(interval: TimeInterval = 1.0) {
        stopPolling()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = self.snapshot()
            if now != self.last {
                self.last = now
                self.onChange?(now)
            }
        }
        timer = t
        t.resume()
    }

    func stopPolling() {
        timer?.cancel()
        timer = nil
    }

    deinit { stopPolling() }
}
