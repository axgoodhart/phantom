import CoreGraphics
import XCTest
@testable import PhantomCore

final class CoreBehaviourTests: XCTestCase {

    // MARK: - Keymap

    func testKeycodeAndNameRoundTrip() {
        for (character, keycode) in Keymap.charToKeycode {
            XCTAssertEqual(Keymap.keycode(forName: String(character)), keycode)
        }
        XCTAssertEqual(Keymap.name(for: 0x24), "return")
        XCTAssertEqual(Keymap.name(for: 0x00), "a")
        XCTAssertNil(Keymap.name(for: 0xFE))
    }

    func testDisplayNamesFollowTheShiftState() {
        XCTAssertEqual(Keymap.displayName(for: 0x00), "a")
        XCTAssertEqual(Keymap.displayName(for: 0x00, shift: true), "A")
        XCTAssertEqual(Keymap.displayName(for: 0x12, shift: true), "!")
        XCTAssertEqual(Keymap.displayName(for: 0x31), "Space")
        XCTAssertEqual(Keymap.displayName(for: 0x37), "Cmd")
        XCTAssertEqual(Keymap.displayName(for: 0xFE), "VK254")
    }

    func testModifierFlagsMapToTheRightMask() {
        XCTAssertEqual(Keymap.modifierFlag(for: 0x38), .maskShift)
        XCTAssertEqual(Keymap.modifierFlag(for: 0x3C), .maskShift)
        XCTAssertEqual(Keymap.modifierFlag(for: 0x37), .maskCommand)
        XCTAssertNil(Keymap.modifierFlag(for: 0x00))
    }

    /// A modifier key event should read as the key itself, not as a chord
    /// with itself.
    func testKeyLabelForChordsAndModifiers() {
        let save = PhantomEvent(t: 0, kind: .keyDown, keycode: 0x01,
                                flags: CGEventFlags.maskCommand.rawValue)
        XCTAssertEqual(save.keyLabel, "Cmd+s")

        let shiftAlone = PhantomEvent(t: 0, kind: .keyDown, keycode: 0x38,
                                      flags: CGEventFlags.maskShift.rawValue)
        XCTAssertEqual(shiftAlone.keyLabel, "Shift")
    }

    // MARK: - Compression

    func testCompressionDropsIdleMovesButKeepsDrags() {
        let events: [PhantomEvent] = [
            .init(t: 0.000, kind: .move, x: 100, y: 100),
            .init(t: 0.002, kind: .move, x: 101, y: 100),   // too close, too soon
            .init(t: 0.004, kind: .move, x: 100, y: 101),   // ditto
            .init(t: 0.020, kind: .move, x: 101, y: 101),   // enough time has passed
            .init(t: 0.030, kind: .move, x: 140, y: 160),   // moved far enough
            .init(t: 0.031, kind: .leftDown, x: 140, y: 160),
            .init(t: 0.032, kind: .drag, x: 141, y: 160),   // drags are never dropped
            .init(t: 0.033, kind: .drag, x: 141, y: 161),
            .init(t: 0.034, kind: .leftUp, x: 141, y: 161),
        ]

        let compressed = WorkflowBuilder.compress(events)
        XCTAssertEqual(compressed.count, 7)
        XCTAssertEqual(compressed.filter { $0.kind == .drag }.count, 2)
        XCTAssertEqual(compressed.first?.x, 100)
    }

    func testCompressionPreservesOrderAndTiming() {
        let events = (0..<200).map {
            PhantomEvent(t: Double($0) * 0.05, kind: .move, x: $0 * 5, y: $0 * 3)
        }
        let compressed = WorkflowBuilder.compress(events)
        XCTAssertEqual(compressed.count, events.count)
        XCTAssertEqual(compressed.map(\.t), events.map(\.t))
    }

    // MARK: - Coordinates

    func testGlobalAndCocoaConversionsAreInverses() {
        let height = Coordinates.primaryHeight
        let global = CGPoint(x: 412, y: 300)
        let cocoa = Coordinates.cocoaPoint(fromGlobal: global)

        XCTAssertEqual(cocoa.y, height - 300, accuracy: 0.001)
        let back = Coordinates.globalPoint(fromCocoa: cocoa)
        XCTAssertEqual(back.x, global.x, accuracy: 0.001)
        XCTAssertEqual(back.y, global.y, accuracy: 0.001)
    }

    /// A window's top edge in global coordinates is what the exclusion zone
    /// depends on; getting the flip wrong would put it on the wrong half of
    /// the screen.
    func testWindowFrameConvertsToGlobalRect() {
        let height = Coordinates.primaryHeight
        let cocoaFrame = CGRect(x: 24, y: 24, width: 216, height: 64)
        let global = Coordinates.globalRect(fromCocoa: cocoaFrame)

        XCTAssertEqual(global.origin.x, 24, accuracy: 0.001)
        XCTAssertEqual(global.origin.y, height - 88, accuracy: 0.001)
        XCTAssertEqual(global.height, 64, accuracy: 0.001)
    }

    func testViewPointIsRelativeToTheWindowTopLeft() {
        let height = Coordinates.primaryHeight
        let windowFrame = CGRect(x: 0, y: 0, width: 1000, height: height)
        let point = Coordinates.viewPoint(fromGlobal: CGPoint(x: 100, y: 50), in: windowFrame)

        XCTAssertEqual(point.x, 100, accuracy: 0.001)
        XCTAssertEqual(point.y, 50, accuracy: 0.001)
    }

    // MARK: - Python export

    /// Export then re-import: the events that come back must match.
    func testPythonExportSurvivesReimport() throws {
        let events: [PhantomEvent] = [
            .init(t: 0.1, kind: .move, x: 10, y: 20),
            .init(t: 0.2, kind: .leftDown, x: 10, y: 20, clickState: 2),
            .init(t: 0.3, kind: .leftUp, x: 10, y: 20, clickState: 2),
            .init(t: 0.4, kind: .keyDown, keycode: 0x01,
                  flags: CGEventFlags.maskCommand.rawValue),
            .init(t: 0.5, kind: .scroll, x: 30, y: 40, dx: -1, dy: 2),
        ]
        let workflow = Workflow(
            name: "Export test",
            environment: EnvironmentSnapshot(
                width: 1496, height: 935,
                windows: [WindowSnapshot(app: "Safari", name: "It's fine",
                                         x: 1, y: 2, w: 3, h: 4)],
                frontmostApp: "Safari"
            ),
            events: events
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-export-\(UUID().uuidString).py")
        try PythonExporter.script(for: workflow).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let reimported = try LegacyPythonWorkflow.load(at: url)
        XCTAssertEqual(reimported.name, "Export test")
        XCTAssertEqual(reimported.environment.frontmostApp, "Safari")
        XCTAssertEqual(reimported.environment.windows.first?.name, "It's fine")
        XCTAssertEqual(reimported.events.count, events.count)
        XCTAssertEqual(reimported.events.map(\.kind), events.map(\.kind))
        XCTAssertEqual(reimported.events[3].keycode, 0x01)
        XCTAssertTrue(reimported.events[3].eventFlags.contains(.maskCommand))
    }
}

/// Playback marks the events it posts so Phantom's own taps can ignore
/// them. If this marker stopped working, a recorded force-stop chord would
/// stop the playback replaying it.
final class SyntheticEventMarkerTests: XCTestCase {

    func testStampedEventsAreRecognised() throws {
        let event = try XCTUnwrap(CGEvent(
            keyboardEventSource: PhantomEventSource.shared, virtualKey: 0x00, keyDown: true
        ))
        XCTAssertFalse(PhantomEventSource.isSynthetic(event))

        PhantomEventSource.stamp(event)
        XCTAssertTrue(PhantomEventSource.isSynthetic(event))
    }

    func testUnstampedMouseEventsAreNotRecognised() throws {
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: PhantomEventSource.shared,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 10, y: 10),
            mouseButton: .left
        ))
        XCTAssertFalse(PhantomEventSource.isSynthetic(event))
    }
}

/// Starting and stopping capture must be safe even without Accessibility
/// permission, which is the state a fresh install is in.
final class RecorderLifecycleTests: XCTestCase {

    func testStopIsSafeWhenCaptureNeverStarted() {
        let recorder = EventRecorder()
        recorder.stopRecording()
        recorder.stopHotkeyMonitor()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.eventCount, 0)
    }

    func testRepeatedStartStopCyclesDoNotWedge() {
        let recorder = EventRecorder()
        for _ in 0..<5 {
            _ = recorder.startRecording()
            XCTAssertTrue(recorder.isRecording)
            recorder.stopRecording()
            XCTAssertFalse(recorder.isRecording)
        }
        XCTAssertEqual(recorder.backend, .none)
    }

    func testExclusionZoneIsAppliedAndCleared() {
        let recorder = EventRecorder()
        recorder.setExclusionZone(CGRect(x: 0, y: 0, width: 100, height: 100))
        recorder.clearExclusionZone()
        XCTAssertFalse(recorder.isRecording)
    }

    func testDrainingPendingEventsEmptiesTheBuffer() {
        let recorder = EventRecorder()
        XCTAssertTrue(recorder.drainPendingEvents().isEmpty)
        recorder.clear()
        XCTAssertTrue(recorder.drainPendingEvents().isEmpty)
    }
}
