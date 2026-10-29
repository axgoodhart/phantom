import AppKit
import SwiftUI

/// The transparent, click-through window covering every display.
///
/// It shows the cursor indicator, click ripples, key popups, the reference
/// grid, and the pre-recording prompt. Outside of that prompt it ignores
/// mouse events entirely so the user keeps working normally underneath.
@MainActor
public final class OverlayController: NSObject {

    public let window: OverlayPanel
    private weak var state: AppState?
    private var keyMonitor: Any?

    public init(state: AppState) {
        self.state = state

        let frame = Coordinates.desktopFrame
        window = OverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Phantom Overlay"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isMovableByWindowBackground = false

        window.contentView = OverlayController.makeHostingView(state: state, frame: frame)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    public func show() {
        window.orderFrontRegardless()
    }

    /// Switches between click-through and accepting input for the prompt.
    public func setInteractive(_ interactive: Bool) {
        window.ignoresMouseEvents = !interactive
        if interactive {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            installKeyMonitor()
        } else {
            removeKeyMonitor()
            window.orderFrontRegardless()
        }
    }

    /// SPACE begins, ESC cancels. A local monitor keeps this working on
    /// macOS 13, where SwiftUI has no key-press modifier.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let state = self.state, state.overlay.promptVisible else { return event }
            switch event.keyCode {
            case 49: // space
                state.confirmRecordingPrompt()
                return nil
            case 53: // escape
                state.cancelRecordingPrompt()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    @objc private func screensChanged() {
        let frame = Coordinates.desktopFrame
        window.setFrame(frame, display: true)
        if let state {
            window.contentView = OverlayController.makeHostingView(state: state, frame: frame)
        }
    }

    private static func makeHostingView(state: AppState, frame: CGRect) -> NSHostingView<some View> {
        let root = OverlayView(windowFrame: frame)
            .environmentObject(state.overlay)
            .environmentObject(state)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        return hosting
    }
}

public final class OverlayPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}
