import AppKit
import SwiftUI

/// The armed-box indicator: an accent-colored outline around whichever input
/// Gaze Mode is currently aimed at. It flares briefly when the target changes
/// (the "as if you clicked it" moment), then settles to a quiet outline that
/// stays as long as that box is the target. Purely visual, never takes a click.
@MainActor
final class HighlightPanelController {

    private var panel: NSPanel?
    private var settleTask: Task<Void, Never>?

    /// Move the outline to a new box, with the arrival flare.
    func show(around rect: CGRect) {
        settleTask?.cancel()

        let padded = rect.insetBy(dx: -4, dy: -4)
        let panel = ensurePanel()
        panel.setFrame(padded, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let panel = self?.panel else { return }
            panel.animator().alphaValue = 0.45
        }
    }

    func hide() {
        settleTask?.cancel()
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: HighlightBorder())
        self.panel = panel
        return panel
    }
}

private struct HighlightBorder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.accentColor, lineWidth: 2.5)
            .padding(1)
    }
}
