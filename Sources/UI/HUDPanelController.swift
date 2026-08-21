import AppKit
import SwiftUI

/// The little floating pill near the bottom of the screen.
///
/// A non-activating panel: it appears over whatever you are working in without
/// stealing focus, follows you into full-screen apps, and never takes a click.
@MainActor
final class HUDPanelController {

    enum Mode: Equatable {
        case recording
        case transcribing
        case done(pasted: Bool)
        case message(String)
    }

    private var panel: NSPanel?
    private let model = HUDModel()
    private var hideTask: Task<Void, Never>?
    /// In Gaze Mode: the frame of the input box being dictated into (Cocoa
    /// coordinates). The pill docks just beneath it instead of bottom-center.
    private var anchor: CGRect?
    /// Inside the box (Gaze Mode's "text appears where you look") rather than
    /// below it.
    private var anchorInside = false

    func show(_ mode: Mode, autoHideAfter seconds: TimeInterval? = nil) {
        hideTask?.cancel()
        model.mode = mode
        if mode == .recording {
            model.elapsed = 0
            model.level = 0
            model.partial = ""
        }

        let panel = ensurePanel()
        position(panel)
        panel.orderFrontRegardless()

        if let seconds {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func update(elapsed: TimeInterval, level: Float) {
        model.elapsed = elapsed
        model.level = level
    }

    /// The live preview text, while recording.
    func updatePartial(_ text: String) {
        guard model.mode == .recording else { return }
        model.partial = text
    }

    func hide() {
        hideTask?.cancel()
        anchor = nil
        panel?.orderOut(nil)
    }

    /// Docks the pill next to a rectangle (or back to bottom-center with nil).
    func setAnchor(_ rect: CGRect?, inside: Bool = false) {
        anchor = rect
        anchorInside = inside
        if let panel, panel.isVisible {
            position(panel)
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let size = panel.frame.size

        if let anchor {
            let screen = NSScreen.screens.first {
                $0.frame.intersects(anchor)
            } ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return }

            var origin: NSPoint
            if anchorInside {
                // At the top of the box itself — the preview reads as text
                // arriving where you are looking.
                origin = NSPoint(
                    x: anchor.minX + 6,
                    y: anchor.maxY - size.height - 6)
            } else {
                // Just under the box, clamped on-screen.
                origin = NSPoint(
                    x: anchor.midX - size.width / 2,
                    y: anchor.minY - size.height - 10)
                if origin.y < visible.minY {
                    origin.y = anchor.maxY + 10  // no room below — sit above
                }
            }
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
            origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
            panel.setFrameOrigin(origin)
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 72)
        panel.setFrameOrigin(origin)
    }
}

/// Observable box so the panel can update without being rebuilt.
final class HUDModel: ObservableObject {
    @Published var mode: HUDPanelController.Mode = .recording
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0
    /// Live preview text while recording; empty until the first pass lands.
    @Published var partial: String = ""
}
