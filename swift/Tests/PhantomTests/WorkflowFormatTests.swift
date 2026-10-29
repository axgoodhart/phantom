import XCTest
@testable import PhantomCore

final class WorkflowFormatTests: XCTestCase {

    private func sampleWorkflow(eventCount: Int = 5) -> Workflow {
        var events: [PhantomEvent] = []
        for index in 0..<eventCount {
            events.append(PhantomEvent(t: Double(index) * 0.1, kind: .move,
                                       x: 100 + index, y: 200 + index))
        }
        events.append(PhantomEvent(t: 1.0, kind: .leftDown, x: 10, y: 20, clickState: 2))
        events.append(PhantomEvent(t: 1.1, kind: .keyDown, keycode: 0x08,
                                   flags: CGEventFlags.maskCommand.rawValue))
        events.append(PhantomEvent(t: 1.2, kind: .scroll, x: 5, y: 6, dx: -1, dy: 3,
                                   pdx: nil, pdy: 42))

        return Workflow(
            name: "Round trip",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            environment: EnvironmentSnapshot(
                width: 1496, height: 935,
                windows: [WindowSnapshot(app: "Safari", name: "It's \"quoted\"",
                                         x: 0, y: 25, w: 1280, h: 800)],
                frontmostApp: "Safari", displayCount: 2, windowNamesAvailable: true
            ),
            options: WorkflowOptions(matchResolution: false, matchWindows: true, defaultSpeed: 2.0),
            events: events
        )
    }

    func testEncodeDecodeRoundTrip() throws {
        let original = sampleWorkflow()
        let decoded = try Workflow.decode(from: try original.encoded())
        XCTAssertEqual(decoded, original)
    }

    /// The header must stay readable and the events must stay one per line,
    /// which is what makes a long workflow greppable and diff-friendly.
    func testFileLayoutIsLineOriented() throws {
        let workflow = sampleWorkflow(eventCount: 20)
        let text = String(decoding: try workflow.encoded(), as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("{\n"))
        XCTAssertTrue(text.contains("\"name\" : \"Round trip\""))

        let eventLines = text.split(separator: "\n").filter { $0.hasPrefix("{\"") }
        XCTAssertEqual(eventLines.count, workflow.events.count)
    }

    /// Listing must not decode the event array.
    func testMetadataIsReadFromTheHeaderAlone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-meta-\(UUID().uuidString)")
        let store = WorkflowStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let workflow = sampleWorkflow(eventCount: 500)
        let url = try store.save(workflow)

        let metadata = try XCTUnwrap(store.metadata(for: url))
        XCTAssertEqual(metadata.name, "Round trip")
        XCTAssertEqual(metadata.actions, workflow.events.count)
        XCTAssertEqual(metadata.resolution, "1496 x 935")
        XCTAssertEqual(metadata.format, .phantom)
    }

    func testStoreResolvesByFilenameNameAndFragment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-resolve-\(UUID().uuidString)")
        let store = WorkflowStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try store.save(sampleWorkflow())
        XCTAssertEqual(store.resolve(url.lastPathComponent)?.url, url)
        XCTAssertEqual(store.resolve("Round trip")?.url, url)
        XCTAssertEqual(store.resolve("round")?.url, url)
        XCTAssertNil(store.resolve("nothing like this"))
    }

    func testDeleteRefusesPathsOutsideTheWorkflowsFolder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-guard-\(UUID().uuidString)")
        let store = WorkflowStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outsider = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-outsider-\(UUID().uuidString).phantom")
        FileManager.default.createFile(atPath: outsider.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: outsider) }

        XCTAssertThrowsError(try store.delete(at: outsider))
        XCTAssertThrowsError(try store.delete(at: directory.appendingPathComponent("../escape.phantom")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsider.path))
    }

    /// A name with newlines or quotes must not be able to corrupt the file.
    func testHostileNamesSurviveRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-names-\(UUID().uuidString)")
        let store = WorkflowStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let hostile = "line\nbreak \"quote\" \\slash\\ 'apostrophe'"
        var workflow = sampleWorkflow()
        workflow.name = hostile

        let url = try store.save(workflow)
        XCTAssertEqual(try Workflow.load(from: url).name, hostile)
        // The metadata scanner must survive it too.
        XCTAssertEqual(store.metadata(for: url)?.name, hostile)
    }

    func testFilenameSlugIsSafeAndStable() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = WorkflowStore.filename(for: "My  Report/2024 ✱", recordedAt: date)
        XCTAssertTrue(name.hasSuffix(".phantom"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasPrefix("my_report_2024_"))
    }
}

import CoreGraphics
