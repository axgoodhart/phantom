import Foundation

/// Owns the workflows folder: listing, saving, renaming, deleting, and
/// reading both the native format and workflows left over from the Python
/// build.
public final class WorkflowStore {

    public static let shared = WorkflowStore()

    public let directory: URL

    public init(directory: URL? = nil) {
        let target = directory ?? WorkflowStore.defaultDirectory
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // Normalise once so every URL this store hands out compares equal to
        // every other, whichever way the caller spelled the path.
        self.directory = target.resolvingSymlinksInPath()
    }

    public static var applicationSupportDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Phantom", isDirectory: true)
    }

    public static var defaultDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("workflows", isDirectory: true)
    }

    // MARK: - Listing

    /// Every readable workflow, newest first. Native files are read header
    /// only; legacy `.py` files are parsed from their docstring.
    public func list() -> [WorkflowMetadata] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [WorkflowMetadata] = []
        for url in entries {
            let ext = url.pathExtension.lowercased()
            guard ext == Workflow.fileExtension || ext == "py" else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            guard let metadata = metadata(for: url.resolvingSymlinksInPath()) else { continue }
            result.append(metadata)
        }
        result.sort { $0.modifiedAt > $1.modifiedAt }
        return result
    }

    public func metadata(for rawURL: URL) -> WorkflowMetadata? {
        let url = rawURL.resolvingSymlinksInPath()
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast

        if url.pathExtension.lowercased() == "py" {
            return LegacyPythonWorkflow.metadata(at: url, modifiedAt: modified)
        }
        return nativeMetadata(at: url, modifiedAt: modified)
    }

    /// Reads only the header of a `.phantom` file. The events array is
    /// always the last key, so the prefix before it is a complete object
    /// once its trailing comma is replaced with a brace.
    private func nativeMetadata(at url: URL, modifiedAt: Date) -> WorkflowMetadata? {
        guard let header = readHeaderObject(at: url) else {
            // Unusual layout (hand-edited, re-serialised): pay for a full parse.
            guard let workflow = try? Workflow.load(from: url) else { return nil }
            return workflow.metadata(url: url, modifiedAt: modifiedAt)
        }

        guard let name = header["name"] as? String else { return nil }
        let width = (header["environment"] as? [String: Any])?["width"] as? Int ?? 0
        let height = (header["environment"] as? [String: Any])?["height"] as? Int ?? 0
        let recordedAt = (header["recordedAt"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }

        return WorkflowMetadata(
            name: name,
            recordedAt: recordedAt,
            resolution: width > 0 ? "\(width) x \(height)" : "",
            actions: header["actionCount"] as? Int ?? 0,
            duration: header["durationSeconds"] as? Double ?? 0,
            url: url,
            format: .phantom,
            modifiedAt: modifiedAt
        )
    }

    private func readHeaderObject(at url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: chunk, encoding: .utf8),
              let eventsKey = text.range(of: "\"events\"")
        else { return nil }

        var prefix = String(text[text.startIndex..<eventsKey.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.hasSuffix(",") else { return nil }
        prefix.removeLast()
        prefix += "}"

        guard let data = prefix.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    // MARK: - Reading

    /// Loads a workflow from either format. Legacy Python workflows are
    /// converted on the fly so the existing library keeps working.
    public func load(at url: URL) throws -> Workflow {
        if url.pathExtension.lowercased() == "py" {
            return try LegacyPythonWorkflow.load(at: url)
        }
        return try Workflow.load(from: url)
    }

    /// Finds a workflow by filename, by name, or by partial name — the
    /// resolution order the CLI uses.
    public func resolve(_ identifier: String) -> WorkflowMetadata? {
        let all = list()

        if let exact = all.first(where: { $0.filename == identifier }) { return exact }
        for ext in [Workflow.fileExtension, "py"] {
            let candidate = "\(identifier).\(ext)"
            if let match = all.first(where: { $0.filename == candidate }) { return match }
        }

        let needle = identifier.lowercased()
        if let exactName = all.first(where: { $0.name.lowercased() == needle }) { return exactName }
        return all.first { $0.name.lowercased().contains(needle) }
    }

    // MARK: - Writing

    @discardableResult
    public func save(_ workflow: Workflow) throws -> URL {
        let url = directory.appendingPathComponent(
            WorkflowStore.filename(for: workflow.name, recordedAt: workflow.recordedAt)
        )
        try workflow.write(to: url)
        return url.resolvingSymlinksInPath()
    }

    public static func filename(for name: String, recordedAt: Date) -> String {
        var slug = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }.reduce(into: "") { partial, character in
            // Collapse runs of separators so the name stays readable.
            if character == "_", partial.last == "_" { return }
            partial.append(character)
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if slug.isEmpty { slug = "workflow" }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(slug)_\(formatter.string(from: recordedAt)).\(Workflow.fileExtension)"
    }

    public func delete(at url: URL) throws {
        try guardInsideDirectory(url)
        try FileManager.default.removeItem(at: url)
    }

    /// Renames the workflow itself. Native files get their `name` rewritten;
    /// legacy files get their docstring header rewritten in place.
    public func rename(at url: URL, to newName: String) throws -> WorkflowMetadata? {
        try guardInsideDirectory(url)
        let cleaned = WorkflowStore.sanitize(name: newName)

        if url.pathExtension.lowercased() == "py" {
            try LegacyPythonWorkflow.rename(at: url, to: cleaned)
        } else {
            var workflow = try Workflow.load(from: url)
            workflow.name = cleaned
            try workflow.write(to: url)
        }
        return metadata(for: url)
    }

    /// Rewrites a legacy `.py` workflow as a native `.phantom` file,
    /// leaving the original untouched.
    @discardableResult
    public func convertLegacy(at url: URL) throws -> URL {
        let workflow = try LegacyPythonWorkflow.load(at: url)
        return try save(workflow)
    }

    /// Path-traversal guard shared by the mutating operations.

    public static func sanitize(name: String) -> String {
        let collapsed = name
            .replacingOccurrences(of: "[\r\n\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "workflow" : collapsed
    }

    private func guardInsideDirectory(_ url: URL) throws {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        // Standardize before resolving so "../escape" is collapsed even when
        // the resulting path does not exist.
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard target.hasPrefix(root + "/") else {
            throw WorkflowError.unreadable("\(url.lastPathComponent) is outside the workflows folder")
        }
    }
}
