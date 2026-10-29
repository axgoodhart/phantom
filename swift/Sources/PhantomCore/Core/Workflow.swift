import CoreGraphics
import Foundation

/// A window's position at recording time, in global top-left coordinates.
public struct WindowSnapshot: Codable, Equatable, Sendable {
    public var app: String
    public var name: String
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(app: String, name: String, x: Int, y: Int, w: Int, h: Int) {
        self.app = app
        self.name = name
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var frame: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
    }
}

/// The stage the recorded actions were performed on. Replay restores this
/// before posting anything, which is what keeps raw coordinates valid.
public struct EnvironmentSnapshot: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var windows: [WindowSnapshot]
    public var frontmostApp: String
    public var displayCount: Int
    /// False when macOS redacted other apps' window titles (no Screen
    /// Recording permission), so restore falls back to "this app's first window".
    public var windowNamesAvailable: Bool

    public init(width: Int, height: Int, windows: [WindowSnapshot] = [],
                frontmostApp: String = "Finder", displayCount: Int = 1,
                windowNamesAvailable: Bool = true) {
        self.width = width
        self.height = height
        self.windows = windows
        self.frontmostApp = frontmostApp
        self.displayCount = displayCount
        self.windowNamesAvailable = windowNamesAvailable
    }

    public var resolution: CGSize { CGSize(width: width, height: height) }
    public var resolutionText: String { "\(width) x \(height)" }
}

/// Defaults chosen when the workflow was recorded. The playback sheet can
/// override them per run.
public struct WorkflowOptions: Codable, Equatable, Sendable {
    public var matchResolution: Bool
    public var matchWindows: Bool
    public var defaultSpeed: Double

    public init(matchResolution: Bool = true, matchWindows: Bool = true,
                defaultSpeed: Double = 1.0) {
        self.matchResolution = matchResolution
        self.matchWindows = matchWindows
        self.defaultSpeed = defaultSpeed
    }
}

/// A complete recording: what was captured, on what stage, and how to replay
/// it. Stored as JSON with a `.phantom` extension.
public struct Workflow: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileExtension = "phantom"

    public var version: Int
    public var name: String
    public var recordedAt: Date
    /// Denormalised so a listing can read the header without decoding
    /// tens of thousands of events.
    public var actionCount: Int
    public var durationSeconds: Double
    public var environment: EnvironmentSnapshot
    public var options: WorkflowOptions
    public var events: [PhantomEvent]

    public init(name: String, recordedAt: Date = Date(),
                environment: EnvironmentSnapshot,
                options: WorkflowOptions = WorkflowOptions(),
                events: [PhantomEvent]) {
        self.version = Workflow.currentVersion
        self.name = name
        self.recordedAt = recordedAt
        self.environment = environment
        self.options = options
        self.events = events
        self.actionCount = events.count
        self.durationSeconds = events.last?.t ?? 0
    }

    public var duration: Double { durationSeconds }

    // MARK: - Coding

    /// The header, encoded separately so it can be read on its own.
    private struct Header: Codable {
        var version: Int
        var name: String
        var recordedAt: Date
        var actionCount: Int
        var durationSeconds: Double
        var environment: EnvironmentSnapshot
        var options: WorkflowOptions
    }

    static func makeEncoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes to valid JSON laid out for humans: a pretty-printed header,
    /// then one compact event per line. A 75,000-event workflow stays
    /// greppable and diffs line by line instead of as one endless string.
    public func encoded() throws -> Data {
        let header = Header(
            version: version, name: name, recordedAt: recordedAt,
            actionCount: events.count, durationSeconds: events.last?.t ?? 0,
            environment: environment, options: options
        )
        var text = String(decoding: try Workflow.makeEncoder(pretty: true).encode(header),
                          as: UTF8.self)

        // Splice the event array in as the last key of the same object.
        guard let closing = text.lastIndex(of: "}") else {
            throw WorkflowError.encodingFailed
        }
        text = String(text[text.startIndex..<closing])
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text += ",\n  \"events\" : [\n"

        let eventEncoder = Workflow.makeEncoder(pretty: false)
        var lines: [String] = []
        lines.reserveCapacity(events.count)
        for event in events {
            lines.append(String(decoding: try eventEncoder.encode(event), as: UTF8.self))
        }
        text += lines.joined(separator: ",\n")
        text += "\n  ]\n}\n"

        guard let data = text.data(using: .utf8) else { throw WorkflowError.encodingFailed }
        return data
    }

    public static func decode(from data: Data) throws -> Workflow {
        try makeDecoder().decode(Workflow.self, from: data)
    }

    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> Workflow {
        try decode(from: try Data(contentsOf: url))
    }
}

public enum WorkflowError: LocalizedError {
    case encodingFailed
    case unreadable(String)
    case notAWorkflow(String)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Could not encode the workflow"
        case .unreadable(let detail): return "Could not read workflow: \(detail)"
        case .notAWorkflow(let name): return "\(name) is not a Phantom workflow"
        }
    }
}

/// The header shown in lists and the playback panel.
public struct WorkflowMetadata: Identifiable, Equatable, Sendable {
    public enum Format: String, Sendable {
        case phantom
        /// A workflow generated by the Python version of Phantom.
        case legacyPython = "python"
    }

    public var name: String
    public var recordedAt: Date?
    public var resolution: String
    public var actions: Int
    public var duration: Double
    public var url: URL
    public var format: Format
    public var modifiedAt: Date

    public var id: URL { url }
    public var filename: String { url.lastPathComponent }

    public init(name: String, recordedAt: Date?, resolution: String, actions: Int,
                duration: Double, url: URL, format: Format, modifiedAt: Date) {
        self.name = name
        self.recordedAt = recordedAt
        self.resolution = resolution
        self.actions = actions
        self.duration = duration
        self.url = url
        self.format = format
        self.modifiedAt = modifiedAt
    }

    public var dateText: String {
        guard let recordedAt else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: recordedAt)
    }

    public var durationText: String { String(format: "%.1fs", duration) }
    public var isLegacy: Bool { format == .legacyPython }
}

extension Workflow {
    public func metadata(url: URL, modifiedAt: Date = Date()) -> WorkflowMetadata {
        WorkflowMetadata(
            name: name,
            recordedAt: recordedAt,
            resolution: environment.resolutionText,
            actions: actionCount,
            duration: durationSeconds,
            url: url,
            format: .phantom,
            modifiedAt: modifiedAt
        )
    }
}
