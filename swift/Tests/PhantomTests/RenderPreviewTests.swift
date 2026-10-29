import SwiftUI
import XCTest
@testable import PhantomCore

/// Renders the panel offscreen so its layout can be reviewed without
/// launching the app. Set PHANTOM_RENDER_DIR to collect the images.
@MainActor
final class RenderPreviewTests: XCTestCase {

    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["PHANTOM_RENDER_DIR"].map {
            URL(fileURLWithPath: $0)
        }
    }

    func testRendersPanelStates() throws {
        guard let directory = outputDirectory else {
            throw XCTSkip("PHANTOM_RENDER_DIR not set")
        }
        Theme.registerFonts()

        try render(name: "01-record-idle", size: CGSize(width: 320, height: 620)) { state in
            state.mode = .record
        }

        try render(name: "02-record-active", size: CGSize(width: 320, height: 620)) { state in
            state.mode = .record
            state.activity = .stopped
            state.statusText = "Stopped: 1080 events, 22.6s"
            state.eventCount = 1080
            state.hasRecording = true
            state.workflowName = "Daily report"
            state.environment = EnvironmentSnapshot(
                width: 1496, height: 935,
                windows: [WindowSnapshot(app: "Safari", name: "Inbox", x: 0, y: 25, w: 1280, h: 800)],
                frontmostApp: "Safari", displayCount: 2, windowNamesAvailable: false
            )
            state.log = [
                .init(time: 0.889, text: "Move (990, 447)", category: .move),
                .init(time: 1.204, text: "Left down (412, 388)", category: .click),
                .init(time: 1.298, text: "Left up (412, 388)", category: .click),
                .init(time: 2.010, text: "Key down: Cmd+s", category: .key),
                .init(time: 2.115, text: "Key up: Cmd+s", category: .key),
                .init(time: 3.400, text: "Scroll (700, 500) dy=-3", category: .scroll),
            ]
        }

        try render(name: "03-playback", size: CGSize(width: 320, height: 620)) { state in
            state.mode = .playback
            state.activity = .playing
            state.statusText = "Playback: 540/1080 (50%)"
            state.isPlaying = true
            state.playbackProgress = 0.5
            state.loopStatus = "Run 2/5"
            state.loadedWorkflow = WorkflowMetadata(
                name: "Testworkflow", recordedAt: Date(), resolution: "1496 x 935",
                actions: 1080, duration: 22.6,
                url: URL(fileURLWithPath: "/tmp/testworkflow.py"),
                format: .legacyPython, modifiedAt: Date()
            )
        }

        try render(name: "04-chip", size: CGSize(width: 216, height: 64)) { state in
            state.isChipMode = true
            state.isRecording = true
            state.eventCount = 342
        }

        try render(name: "05-workflows", size: CGSize(width: 400, height: 420)) { state in
            state.mode = .playback
            state.showWorkflowBrowser = true
            state.workflows = [
                .init(name: "Testworkflow", recordedAt: Date(), resolution: "1496 x 935",
                      actions: 1080, duration: 22.6,
                      url: URL(fileURLWithPath: "/tmp/a.phantom"),
                      format: .phantom, modifiedAt: Date()),
                .init(name: "Peppercheese", recordedAt: Date(), resolution: "1496 x 935",
                      actions: 773, duration: 35.2,
                      url: URL(fileURLWithPath: "/tmp/b.py"),
                      format: .legacyPython, modifiedAt: Date()),
            ]
            state.selectedWorkflow = state.workflows.first
        } content: {
            AnyView(ModalBackdrop { WorkflowBrowserView() })
        }

        try render(name: "06-playback-options", size: CGSize(width: 380, height: 420)) { state in
            state.mode = .playback
        } content: {
            AnyView(ModalBackdrop { PlaybackOptionsView() })
        }

        try render(name: "07-permissions", size: CGSize(width: 380, height: 320)) { state in
            state.permissions = .init(accessibility: false, screenRecording: false)
        } content: {
            AnyView(ModalBackdrop { PermissionsView() })
        }

        // ScrollView, Slider and TextField do not draw through ImageRenderer,
        // so render the sections directly to check their layout.
        try render(name: "09-record-sections", size: CGSize(width: 320, height: 900)) { state in
            state.mode = .record
            state.hasRecording = true
            state.eventCount = 1080
            state.workflowName = "Daily report"
            state.environment = EnvironmentSnapshot(
                width: 1496, height: 935,
                windows: [WindowSnapshot(app: "Safari", name: "Inbox", x: 0, y: 25, w: 1280, h: 800)],
                frontmostApp: "Safari", displayCount: 2, windowNamesAvailable: false
            )
            state.log = [
                .init(time: 0.889, text: "Move (990, 447)", category: .move),
                .init(time: 1.204, text: "Left down (412, 388)", category: .click),
                .init(time: 2.010, text: "Key down: Cmd+s", category: .key),
                .init(time: 3.400, text: "Scroll (700, 500) dy=-3", category: .scroll),
            ]
        } content: {
            AnyView(VStack(spacing: 0) { RecordPanelView() }.background(Theme.background))
        }

        try render(name: "10-playback-sections", size: CGSize(width: 320, height: 620)) { state in
            state.mode = .playback
            state.isPlaying = true
            state.playbackProgress = 0.5
            state.loopStatus = "Run 2/5"
            state.loadedWorkflow = WorkflowMetadata(
                name: "Testworkflow", recordedAt: Date(), resolution: "1496 x 935",
                actions: 1080, duration: 22.6,
                url: URL(fileURLWithPath: "/tmp/testworkflow.py"),
                format: .legacyPython, modifiedAt: Date()
            )
        } content: {
            AnyView(VStack(spacing: 0) { PlaybackPanelView() }.background(Theme.background))
        }

        try render(name: "08-record-prompt", size: CGSize(width: 520, height: 420)) { state in
            state.overlay.promptVisible = true
        } content: {
            AnyView(
                OverlayView(windowFrame: CGRect(x: 0, y: 0, width: 520, height: 420))
                    .background(Color(hex: 0x1A1A1A))
            )
        }
    }

    private func render(
        name: String,
        size: CGSize,
        configure: (AppState) -> Void,
        content: (() -> AnyView)? = nil
    ) throws {
        guard let directory = outputDirectory else { return }
        let state = AppState(store: WorkflowStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-render-\(UUID().uuidString)")))
        configure(state)

        let view = (content?() ?? AnyView(ControlPanelView()))
            .environmentObject(state)
            .environmentObject(state.overlay)
            .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            XCTFail("Could not render \(name)")
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
