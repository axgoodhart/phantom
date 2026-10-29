import CoreGraphics
import Foundation

/// Reads the standalone `.py` workflows the Python version of Phantom
/// generated, so an existing library keeps working after the rewrite.
///
/// The files are ordinary Python, but the parts Phantom wrote are highly
/// regular: a docstring header, a `WINDOWS` list, a `FRONTMOST_APP` string,
/// and an `EVENTS` list of tuples. Only those are read — nothing is executed.
public enum LegacyPythonWorkflow {

    // MARK: - Metadata

    public static func metadata(at url: URL, modifiedAt: Date) -> WorkflowMetadata? {
        guard let head = readHead(of: url, bytes: 4096) else { return nil }
        guard let name = capture(#"Workflow:\s*(.+)"#, in: head) else { return nil }

        let resolution = capture(#"Resolution:\s*(\d+)\s*x\s*(\d+)"#, in: head, groups: 2)
            .map { "\($0[0]) x \($0[1])" } ?? ""
        let actions = capture(#"Actions:\s*(\d+)"#, in: head).flatMap(Int.init) ?? 0
        let duration = capture(#"Duration:\s*([\d.]+)"#, in: head).flatMap(Double.init) ?? 0
        let recordedAt = capture(#"Recorded:\s*(.+)"#, in: head).flatMap { text -> Date? in
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
        }

        return WorkflowMetadata(
            name: name.trimmingCharacters(in: .whitespaces),
            recordedAt: recordedAt,
            resolution: resolution,
            actions: actions,
            duration: duration,
            url: url,
            format: .legacyPython,
            modifiedAt: modifiedAt
        )
    }

    // MARK: - Loading

    public static func load(at url: URL) throws -> Workflow {
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw WorkflowError.unreadable(error.localizedDescription)
        }

        guard let name = capture(#"Workflow:\s*(.+)"#, in: source)?
            .trimmingCharacters(in: .whitespaces)
        else {
            throw WorkflowError.notAWorkflow(url.lastPathComponent)
        }

        let width = capture(#"Resolution:\s*(\d+)\s*x\s*(\d+)"#, in: source, groups: 2)
        let recordedAt = capture(#"Recorded:\s*(.+)"#, in: source).flatMap { text -> Date? in
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
        }

        let environment = EnvironmentSnapshot(
            width: width.flatMap { Int($0[0]) } ?? 0,
            height: width.flatMap { Int($0[1]) } ?? 0,
            windows: parseWindows(in: source),
            frontmostApp: parseFrontmost(in: source) ?? "Finder",
            displayCount: 1,
            windowNamesAvailable: true
        )

        let options = WorkflowOptions(
            matchResolution: !(parseBool("SKIP_RESOLUTION", in: source) ?? false),
            matchWindows: !(parseBool("SKIP_WINDOWS", in: source) ?? false),
            defaultSpeed: parseDouble("SPEED", in: source) ?? 1.0
        )

        return Workflow(
            name: name,
            recordedAt: recordedAt ?? fileDate(of: url),
            environment: environment,
            options: options,
            events: parseEvents(in: source)
        )
    }

    /// Rewrites the `Workflow:` line in place, matching how the Python CLI
    /// renamed a workflow.
    public static func rename(at url: URL, to newName: String) throws {
        var source = try String(contentsOf: url, encoding: .utf8)
        guard let regex = try? NSRegularExpression(
            pattern: #"^(Workflow:[ \t]*)(.*)$"#, options: [.anchorsMatchLines]
        ) else { throw WorkflowError.encodingFailed }

        let range = NSRange(source.startIndex..., in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              let prefixRange = Range(match.range(at: 1), in: source),
              let valueRange = Range(match.range(at: 2), in: source)
        else { throw WorkflowError.notAWorkflow(url.lastPathComponent) }

        // Replace only the value, so an unusual name cannot inject a newline
        // into the docstring and break the header.
        let safeName = newName.replacingOccurrences(
            of: "[\r\n]+", with: " ", options: .regularExpression
        )
        source.replaceSubrange(valueRange, with: safeName)
        _ = prefixRange
        try source.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Section parsing

    static func parseFrontmost(in source: String) -> String? {
        guard let range = source.range(of: #"FRONTMOST_APP\s*=\s*"#, options: .regularExpression)
        else { return nil }
        var scanner = PythonLiteralScanner(String(source[range.upperBound...]))
        return scanner.scanString()
    }

    static func parseBool(_ variable: String, in source: String) -> Bool? {
        guard let value = capture("^\\s*\(variable)\\s*=\\s*(True|False)\\s*$", in: source,
                                  options: [.anchorsMatchLines])
        else { return nil }
        return value == "True"
    }

    static func parseDouble(_ variable: String, in source: String) -> Double? {
        capture("^\\s*\(variable)\\s*=\\s*([\\d.]+)\\s*$", in: source,
                options: [.anchorsMatchLines]).flatMap(Double.init)
    }

    static func parseWindows(in source: String) -> [WindowSnapshot] {
        guard let body = arrayBody(after: #"WINDOWS\s*=\s*"#, in: source) else { return [] }

        var windows: [WindowSnapshot] = []
        // Each window is one `{"app": ..., "name": ..., "x": ...}` line.
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            guard let app = dictString("app", in: trimmed) else { continue }
            windows.append(WindowSnapshot(
                app: app,
                name: dictString("name", in: trimmed) ?? "Untitled",
                x: dictInt("x", in: trimmed) ?? 0,
                y: dictInt("y", in: trimmed) ?? 0,
                w: dictInt("w", in: trimmed) ?? 0,
                h: dictInt("h", in: trimmed) ?? 0
            ))
        }
        return windows
    }

    static func parseEvents(in source: String) -> [PhantomEvent] {
        guard let body = arrayBody(after: #"EVENTS\s*=\s*"#, in: source) else { return [] }

        var scanner = PythonLiteralScanner(body)
        var events: [PhantomEvent] = []
        while let tuple = scanner.scanTuple() {
            if let event = event(from: tuple) { events.append(event) }
        }
        return events
    }

    /// Contents of the bracketed list that follows `pattern`.
    private static func arrayBody(after pattern: String, in source: String) -> String? {
        guard let match = source.range(of: pattern, options: .regularExpression) else { return nil }
        let remainder = source[match.upperBound...]
        guard let open = remainder.firstIndex(of: "[") else { return nil }

        var depth = 0
        var index = open
        while index < remainder.endIndex {
            let character = remainder[index]
            if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 {
                    return String(remainder[remainder.index(after: open)..<index])
                }
            }
            index = remainder.index(after: index)
        }
        return nil
    }

    private static func event(from tuple: [PythonValue]) -> PhantomEvent? {
        guard tuple.count >= 2,
              let t = tuple[0].doubleValue,
              let rawKind = tuple[1].stringValue,
              let kind = PhantomEvent.Kind(rawValue: rawKind)
        else { return nil }

        switch kind {
        case .keyDown, .keyUp:
            guard let code = tuple.count > 2 ? tuple[2].intValue : nil else { return nil }
            let flags = tuple.count > 3 ? (tuple[3].intValue ?? 0) : 0
            return PhantomEvent(t: t, kind: kind, keycode: CGKeyCode(truncatingIfNeeded: code),
                                flags: UInt64(bitPattern: Int64(flags)))
        case .scroll:
            guard tuple.count >= 4, let x = tuple[2].intValue, let y = tuple[3].intValue
            else { return nil }
            return PhantomEvent(t: t, kind: kind, x: x, y: y,
                                dx: tuple.count > 4 ? tuple[4].intValue : 0,
                                dy: tuple.count > 5 ? tuple[5].intValue : 0)
        default:
            guard tuple.count >= 4, let x = tuple[2].intValue, let y = tuple[3].intValue
            else { return nil }
            return PhantomEvent(t: t, kind: kind, x: x, y: y)
        }
    }

    // MARK: - Small helpers

    private static func fileDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
    }

    private static func readHead(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func dictString(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: "\"\(key)\"\\s*:\\s*", options: .regularExpression)
        else { return nil }
        var scanner = PythonLiteralScanner(String(line[range.upperBound...]))
        return scanner.scanString()
    }

    private static func dictInt(_ key: String, in line: String) -> Int? {
        capture("\"\(key)\"\\s*:\\s*(-?\\d+)", in: line).flatMap(Int.init)
    }

    private static func capture(_ pattern: String, in text: String,
                                options: NSRegularExpression.Options = []) -> String? {
        capture(pattern, in: text, groups: 1, options: options)?.first
    }

    private static func capture(_ pattern: String, in text: String, groups: Int,
                                options: NSRegularExpression.Options = []) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        var result: [String] = []
        for index in 1...max(1, groups) {
            guard index < match.numberOfRanges,
                  let range = Range(match.range(at: index), in: text) else { return nil }
            result.append(String(text[range]))
        }
        return result
    }
}

// MARK: - Python literal scanning

enum PythonValue {
    case number(Double)
    case string(String)
    case identifier(String)

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value.rounded()) }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

/// A minimal scanner for the subset of Python literals Phantom's generator
/// emitted: tuples of numbers and quoted strings. It never evaluates code.
struct PythonLiteralScanner {
    private let characters: [Character]
    private var index: Int = 0

    init(_ text: String) {
        characters = Array(text)
    }

    private var current: Character? {
        index < characters.count ? characters[index] : nil
    }

    private mutating func skipWhitespaceAndSeparators() {
        while let character = current,
              character.isWhitespace || character == "," {
            index += 1
        }
    }

    /// Scans the next `( ... )` tuple, or returns nil at the end of input.
    mutating func scanTuple() -> [PythonValue]? {
        skipWhitespaceAndSeparators()
        guard current == "(" else { return nil }
        index += 1

        var values: [PythonValue] = []
        while true {
            skipWhitespaceAndSeparators()
            guard let character = current else { return values.isEmpty ? nil : values }
            if character == ")" {
                index += 1
                return values
            }
            guard let value = scanValue() else {
                // Unrecognised token: skip it so one odd entry cannot
                // abandon the rest of the file.
                index += 1
                continue
            }
            values.append(value)
        }
    }

    mutating func scanString() -> String? {
        skipWhitespaceAndSeparators()
        guard let quote = current, quote == "'" || quote == "\"" else { return nil }
        index += 1

        var result = ""
        while let character = current {
            index += 1
            if character == quote { return result }
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escaped = current else { break }
            index += 1
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "x": result.append(scanHex(digits: 2) ?? "?")
            case "u": result.append(scanHex(digits: 4) ?? "?")
            case "U": result.append(scanHex(digits: 8) ?? "?")
            default: result.append(escaped)
            }
        }
        return result
    }

    private mutating func scanHex(digits: Int) -> Character? {
        var hex = ""
        for _ in 0..<digits {
            guard let character = current, character.isHexDigit else { return nil }
            hex.append(character)
            index += 1
        }
        guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            return nil
        }
        return Character(scalar)
    }

    private mutating func scanValue() -> PythonValue? {
        guard let character = current else { return nil }

        if character == "'" || character == "\"" {
            return scanString().map { PythonValue.string($0) }
        }

        if character == "-" || character == "+" || character.isNumber || character == "." {
            var text = String(character)
            index += 1
            while let next = current,
                  next.isNumber || next == "." || next == "e" || next == "E"
                    || next == "-" || next == "+" {
                text.append(next)
                index += 1
            }
            return Double(text).map { PythonValue.number($0) }
        }

        if character.isLetter || character == "_" {
            var text = ""
            while let next = current, next.isLetter || next.isNumber || next == "_" {
                text.append(next)
                index += 1
            }
            // `True`/`False`/`None` show up in hand-edited files.
            switch text {
            case "True": return .number(1)
            case "False", "None": return .number(0)
            default: return .identifier(text)
            }
        }

        return nil
    }
}
