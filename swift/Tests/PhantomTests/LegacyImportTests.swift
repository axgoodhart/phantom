import XCTest
@testable import PhantomCore

/// The migration path matters more than anything else in the rewrite: an
/// existing library of `.py` workflows has to survive it intact.
final class LegacyImportTests: XCTestCase {

    private func makeLegacySource(events: String, windows: String = "[]") -> String {
        """
        #!/usr/bin/env python3
        # -*- coding: utf-8 -*-
        \"\"\"
        Workflow: Test Flow
        Recorded: 2026-08-06 15:43:53
        Resolution: 1496 x 935
        Actions: 4
        Duration: 22.6s
        \"\"\"

        SPEED = 1.0
        SKIP_RESOLUTION = False
        SKIP_WINDOWS = True

        RESOLUTION = (1496, 935)
        WINDOWS = \(windows)
        FRONTMOST_APP = 'Safari'

        EVENTS = \(events)
        """
    }

    private func loadTemporary(_ source: String) throws -> Workflow {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-test-\(UUID().uuidString).py")
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try LegacyPythonWorkflow.load(at: url)
    }

    func testParsesHeaderAndOptions() throws {
        let workflow = try loadTemporary(makeLegacySource(events: "[]"))

        XCTAssertEqual(workflow.name, "Test Flow")
        XCTAssertEqual(workflow.environment.width, 1496)
        XCTAssertEqual(workflow.environment.height, 935)
        XCTAssertEqual(workflow.environment.frontmostApp, "Safari")
        XCTAssertTrue(workflow.options.matchResolution)
        XCTAssertFalse(workflow.options.matchWindows)
    }

    func testParsesEveryEventShape() throws {
        let events = """
        [
            (0.8893, 'move', 990, 447),
            (1.0, 'left_down', 100, 200),
            (1.1, 'drag', 110, 210),
            (1.2, 'left_up', 120, 220),
            (1.3, 'right_down', 5, 6),
            (1.4, 'right_drag', 7, 8),
            (1.5, 'right_up', 9, 10),
            (1.6, 'middle_down', 11, 12),
            (1.7, 'middle_up', 13, 14),
            (2.0, 'key_down', 8, 1048576),
            (2.1, 'key_up', 8, 1048576),
            (3.0, 'scroll', 300, 400, -1, 2),
        ]
        """
        let workflow = try loadTemporary(makeLegacySource(events: events))

        XCTAssertEqual(workflow.events.count, 12)
        XCTAssertEqual(workflow.events[0].kind, .move)
        XCTAssertEqual(workflow.events[0].t, 0.8893, accuracy: 0.0001)
        XCTAssertEqual(workflow.events[0].x, 990)
        XCTAssertEqual(workflow.events[0].y, 447)

        let keyDown = workflow.events[9]
        XCTAssertEqual(keyDown.kind, .keyDown)
        XCTAssertEqual(keyDown.keycode, 8)                       // 'c'
        XCTAssertTrue(keyDown.eventFlags.contains(.maskCommand)) // 1048576
        XCTAssertEqual(keyDown.keyLabel, "Cmd+c")

        let scroll = workflow.events[11]
        XCTAssertEqual(scroll.kind, .scroll)
        XCTAssertEqual(scroll.dx, -1)
        XCTAssertEqual(scroll.dy, 2)
    }

    func testParsesWindowsIncludingEscapedTitles() throws {
        let windows = """
        [
            {"app": 'Safari', "name": 'It\\'s a title', "x": 0, "y": 25, "w": 1280, "h": 800},
            {"app": 'Code', "name": 'Untitled', "x": -10, "y": 0, "w": 900, "h": 600},
        ]
        """
        let workflow = try loadTemporary(makeLegacySource(events: "[]", windows: windows))

        XCTAssertEqual(workflow.environment.windows.count, 2)
        XCTAssertEqual(workflow.environment.windows[0].app, "Safari")
        XCTAssertEqual(workflow.environment.windows[0].name, "It's a title")
        XCTAssertEqual(workflow.environment.windows[0].w, 1280)
        XCTAssertEqual(workflow.environment.windows[1].x, -10)
    }

    func testMalformedEntryDoesNotAbandonTheRest() throws {
        let events = """
        [
            (0.1, 'move', 1, 2),
            (0.2, 'nonsense_kind', 3, 4),
            (0.3, 'move', 5, 6),
        ]
        """
        let workflow = try loadTemporary(makeLegacySource(events: events))

        XCTAssertEqual(workflow.events.count, 2)
        XCTAssertEqual(workflow.events.last?.x, 5)
    }

    func testRejectsFilesThatAreNotWorkflows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-test-\(UUID().uuidString).py")
        try "print('hello')\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try LegacyPythonWorkflow.load(at: url))
    }

    /// Reads whatever the user actually has on disk. Skips when the folder is
    /// empty so the suite still passes on a clean machine.
    func testImportsWorkflowsFromTheRealLibrary() throws {
        let directory = WorkflowStore.defaultDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "py" } ?? []

        let nonEmpty = files.filter {
            ((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
        }
        try XCTSkipIf(nonEmpty.isEmpty, "No legacy workflows on this machine")

        for url in nonEmpty {
            let workflow = try LegacyPythonWorkflow.load(at: url)
            XCTAssertFalse(workflow.name.isEmpty, "\(url.lastPathComponent) lost its name")
            XCTAssertFalse(workflow.events.isEmpty, "\(url.lastPathComponent) lost its events")

            // Timestamps must stay monotonic or replay scheduling breaks.
            var previous = -Double.infinity
            for event in workflow.events {
                XCTAssertGreaterThanOrEqual(event.t, previous, "\(url.lastPathComponent)")
                previous = event.t
            }
        }
    }
}
