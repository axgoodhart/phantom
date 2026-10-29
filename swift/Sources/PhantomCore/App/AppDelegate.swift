import AppKit
import SwiftUI

/// Agent app: no Dock icon, two floating windows, and a control socket the
/// CLI talks to.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private var state: AppState!
    private var panel: PanelController!
    private var overlay: OverlayController!
    private var controlServer: ControlSocket.Server?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.registerFonts()

        state = AppState()
        panel = PanelController(state: state)
        overlay = OverlayController(state: state)
        state.panel = panel
        state.overlayWindow = overlay

        buildMenu()

        overlay.show()
        panel.show()
        state.start()

        startControlServer()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
        state?.shutdown()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Control socket

    private func startControlServer() {
        let server = ControlSocket.Server { [weak self] request in
            guard let self else {
                return ControlSocket.Response(status: "error", message: "App is shutting down")
            }
            return self.handleBlocking(request)
        }
        do {
            try server.start()
            controlServer = server
        } catch {
            NSLog("Phantom: control socket unavailable — %@", error.localizedDescription)
        }
    }

    /// Bridges the socket's background thread onto the main actor.
    private nonisolated func handleBlocking(
        _ request: ControlSocket.Request
    ) -> ControlSocket.Response {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        Task { @MainActor in
            box.value = self.handle(request)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 20)
        return box.value ?? ControlSocket.Response(status: "error", message: "Timed out")
    }

    private func handle(_ request: ControlSocket.Request) -> ControlSocket.Response {
        switch request.command {
        case "ping":
            return ControlSocket.Response(
                status: "ok",
                accessibility: state.permissions.accessibility,
                screenRecording: state.permissions.screenRecording
            )

        case "record":
            state.switchMode(.record)
            panel.show()
            state.beginRecordingFlow()
            return ControlSocket.Response(status: "prompting")

        case "run":
            guard let identifier = request.workflow,
                  let metadata = state.store.resolve(identifier)
            else {
                return ControlSocket.Response(status: "error", message: "Workflow not found")
            }
            guard !state.isPlaying else {
                return ControlSocket.Response(status: "error",
                                              message: "A workflow is already running")
            }
            guard state.permissions.isReady else {
                state.showPermissionSheet = true
                return ControlSocket.Response(status: "error",
                                              message: "Accessibility permission is not granted")
            }

            state.switchMode(.playback)
            state.loadWorkflow(metadata)
            state.playbackOptions.speed = request.speed ?? 1.0
            state.playbackOptions.matchResolution = request.matchResolution ?? true
            state.playbackOptions.matchWindows = request.matchWindows ?? true
            let loop = request.loop ?? 1
            state.playbackOptions.loopInfinite = loop == 0
            state.playbackOptions.loopCount = max(1, loop)
            state.playbackOptions.loopDelay = request.loopDelay ?? 0
            state.startPlayback()

            return ControlSocket.Response(status: "started", workflow: metadata.name)

        case "stop":
            guard state.isPlaying else { return ControlSocket.Response(status: "not_running") }
            state.stopPlayback()
            return ControlSocket.Response(status: "stopped")

        case "status":
            state.refreshPermissions()
            if state.isRecording {
                return ControlSocket.Response(
                    status: "recording", current: state.eventCount,
                    accessibility: state.permissions.accessibility,
                    screenRecording: state.permissions.screenRecording
                )
            }
            guard state.isPlaying else {
                return ControlSocket.Response(
                    status: "idle",
                    accessibility: state.permissions.accessibility,
                    screenRecording: state.permissions.screenRecording
                )
            }
            return ControlSocket.Response(
                status: "running",
                workflow: state.loadedWorkflow?.name,
                progress: state.playbackProgress,
                accessibility: state.permissions.accessibility,
                screenRecording: state.permissions.screenRecording
            )

        default:
            return ControlSocket.Response(status: "error",
                                          message: "Unknown command: \(request.command)")
        }
    }

    // MARK: - Menu

    /// A minimal menu so the standard text-editing and quit shortcuts work
    /// even though there is no Dock icon.
    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Phantom", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Phantom", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Phantom",
            .init(rawValue: "Copyright"): "Records what you do, then does it again.",
        ])
    }
}

/// Small reference box so a value can cross the actor hop above.
private final class ResponseBox: @unchecked Sendable {
    var value: ControlSocket.Response?
}
