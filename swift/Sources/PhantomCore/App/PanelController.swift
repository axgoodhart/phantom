import AppKit
import SwiftUI

/// The floating control panel.
///
/// While recording it collapses into a small stop chip pinned to the bottom
/// left, so the panel is not sitting in the middle of whatever is being
/// recorded — and so its own clicks stay out of the capture.
@MainActor
public final class PanelController: NSObject {

    public static let defaultSize = CGSize(width: 320, height: 620)
    public static let minimumSize = CGSize(width: 280, height: 500)
    static let chipSize = CGSize(width: 216, height: 64)
    static let margin: CGFloat = 24

    public let window: PhantomPanel
    private var savedFrame: NSRect?
    private weak var state: AppState?

    public init(state: AppState) {
        self.state = state

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screen.minX + PanelController.margin,
            y: screen.minY + PanelController.margin
        )
        window = PhantomPanel(
            contentRect: NSRect(origin: origin, size: PanelController.defaultSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Phantom"
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = PanelController.minimumSize
        let hosting = NSHostingView(rootView: ControlPanelView().environmentObject(state))
        // Without this the hosting view reports the full height of its
        // content as an intrinsic size and AppKit grows the window to match,
        // which turns a 620pt panel into a 1700pt one.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.delegate = self
    }

    public func show() {
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// The panel's frame in the global input coordinate space, which is what
    /// the recorder's exclusion zone speaks.
    public var globalFrame: CGRect {
        Coordinates.globalRect(fromCocoa: window.frame)
    }

    // MARK: - Chip mode

    public func enterChipMode() {
        guard savedFrame == nil else { return }
        savedFrame = window.frame

        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let target = NSRect(
            x: screen.minX + PanelController.margin,
            y: screen.minY + PanelController.margin,
            width: PanelController.chipSize.width,
            height: PanelController.chipSize.height
        )

        // Move the exclusion zone first: the animated resize is synchronous
        // and clicks landing during it should already be excluded.
        state?.setExclusionZone(cocoaFrame: target)

        window.minSize = NSSize(width: 1, height: 1)
        window.isMovableByWindowBackground = false
        window.setFrame(target, display: true, animate: true)
    }

    public func exitChipMode() {
        guard let frame = savedFrame else { return }
        savedFrame = nil
        window.minSize = PanelController.minimumSize
        window.isMovableByWindowBackground = true
        window.setFrame(frame, display: true, animate: true)
    }
}

extension PanelController: NSWindowDelegate {
    public func windowDidMove(_ notification: Notification) {
        state?.updateExclusionZoneForChip()
    }

    public func windowDidResize(_ notification: Notification) {
        state?.updateExclusionZoneForChip()
    }
}

/// A borderless panel that still accepts keyboard focus, so the workflow
/// name field is usable without the app stealing activation.
public final class PhantomPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}
