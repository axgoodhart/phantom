import AppKit
import Foundation

/// `phantom list|run|stop|status|record|delete|rename|inspect|convert|export`
///
/// Every command prints JSON so other tools can consume it; `--pretty` adds a
/// human-readable table first. File operations run locally; anything that
/// posts input is handed to the running app over the control socket.
public enum CommandLineInterface {

    public static let commands: Set<String> = [
        "list", "run", "stop", "status", "record",
        "delete", "rename", "inspect", "convert", "export", "doctor", "help",
    ]

    public static func run(arguments: [String]) -> Never {
        var args = arguments
        let pretty = args.contains("--pretty")
        args.removeAll { $0 == "--pretty" }

        guard let command = args.first(where: { commands.contains($0) }) else {
            printUsage()
            exit(1)
        }
        var rest = args
        if let index = rest.firstIndex(of: command) { rest.removeSubrange(...index) }

        let result: [String: Any]
        switch command {
        case "list": result = list()
        case "run": result = runWorkflow(rest)
        case "stop": result = stop()
        case "status": result = status()
        case "record": result = record()
        case "delete": result = delete(rest)
        case "rename": result = rename(rest)
        case "inspect": result = inspect(rest)
        case "convert": result = convert(rest)
        case "export": result = export(rest)
        case "doctor": result = doctor()
        default:
            printUsage()
            exit(0)
        }

        emit(result, pretty: pretty)
        exit((result["status"] as? String) == "error" ? 1 : 0)
    }

    // MARK: - Commands

    private static func list() -> [String: Any] {
        let workflows = WorkflowStore.shared.list()
        return [
            "status": "ok",
            "count": workflows.count,
            "workflows": workflows.map(describe),
        ]
    }

    private static func runWorkflow(_ args: [String]) -> [String: Any] {
        guard let identifier = args.first, !identifier.hasPrefix("--") else {
            return error("Usage: phantom run <workflow> [--speed N] [--loop N] "
                         + "[--loop-delay N] [--skip-resolution] [--skip-windows]")
        }
        guard let workflow = WorkflowStore.shared.resolve(identifier) else {
            return error("Workflow not found: \(identifier)")
        }

        let request = ControlSocket.Request(
            command: "run",
            workflow: workflow.filename,
            speed: doubleFlag("--speed", in: args) ?? 1.0,
            loop: intFlag("--loop", in: args) ?? 1,
            loopDelay: doubleFlag("--loop-delay", in: args) ?? 0,
            matchResolution: !args.contains("--skip-resolution"),
            matchWindows: !args.contains("--skip-windows")
        )

        guard let response = sendLaunchingIfNeeded(request) else {
            return error("Phantom is not running and could not be launched. "
                         + "Open Phantom.app, then try again.")
        }
        return dictionary(from: response, extra: ["workflow": workflow.name])
    }

    private static func stop() -> [String: Any] {
        guard let response = ControlSocket.send(ControlSocket.Request(command: "stop")) else {
            return ["status": "not_running"]
        }
        return dictionary(from: response)
    }

    private static func status() -> [String: Any] {
        guard let response = ControlSocket.send(ControlSocket.Request(command: "status")) else {
            return ["status": "not_running"]
        }
        return dictionary(from: response)
    }

    private static func record() -> [String: Any] {
        guard let url = appBundleURL() else {
            return error("Phantom.app not found. Build it with Scripts/build_app.sh.")
        }
        NSWorkspace.shared.open(url)
        // Ask the running app to open the recording prompt, once it is up.
        if waitForSocket(timeout: 8) {
            _ = ControlSocket.send(ControlSocket.Request(command: "record"))
        }
        return ["status": "launching", "path": url.path]
    }

    private static func delete(_ args: [String]) -> [String: Any] {
        guard let identifier = args.first else { return error("Usage: phantom delete <workflow>") }
        guard let workflow = WorkflowStore.shared.resolve(identifier) else {
            return error("Workflow not found: \(identifier)")
        }
        do {
            try WorkflowStore.shared.delete(at: workflow.url)
            return ["status": "deleted", "filename": workflow.filename]
        } catch {
            return self.error(error.localizedDescription)
        }
    }

    private static func rename(_ args: [String]) -> [String: Any] {
        guard args.count >= 2 else {
            return error("Usage: phantom rename <workflow> <new-name>")
        }
        guard let workflow = WorkflowStore.shared.resolve(args[0]) else {
            return error("Workflow not found: \(args[0])")
        }
        do {
            let updated = try WorkflowStore.shared.rename(
                at: workflow.url, to: args.dropFirst().joined(separator: " ")
            )
            return ["status": "ok", "metadata": updated.map(describe) ?? [:]]
        } catch {
            return self.error(error.localizedDescription)
        }
    }

    private static func inspect(_ args: [String]) -> [String: Any] {
        guard let identifier = args.first else { return error("Usage: phantom inspect <workflow>") }
        guard let metadata = WorkflowStore.shared.resolve(identifier) else {
            return error("Workflow not found: \(identifier)")
        }
        do {
            let workflow = try WorkflowStore.shared.load(at: metadata.url)
            return [
                "status": "ok",
                "filename": metadata.filename,
                "metadata": describe(metadata),
                "count": workflow.events.count,
                "events": workflow.events.map(describe),
            ]
        } catch {
            return self.error(error.localizedDescription)
        }
    }

    private static func convert(_ args: [String]) -> [String: Any] {
        guard let identifier = args.first else {
            return error("Usage: phantom convert <workflow>   # legacy .py to native .phantom")
        }
        guard let metadata = WorkflowStore.shared.resolve(identifier) else {
            return error("Workflow not found: \(identifier)")
        }
        guard metadata.isLegacy else {
            return error("\(metadata.filename) is already in the native format")
        }
        do {
            let url = try WorkflowStore.shared.convertLegacy(at: metadata.url)
            return ["status": "converted", "filename": url.lastPathComponent]
        } catch {
            return self.error(error.localizedDescription)
        }
    }

    private static func export(_ args: [String]) -> [String: Any] {
        guard let identifier = args.first else {
            return error("Usage: phantom export <workflow> [--to <path.py>]")
        }
        guard let metadata = WorkflowStore.shared.resolve(identifier) else {
            return error("Workflow not found: \(identifier)")
        }
        do {
            let workflow = try WorkflowStore.shared.load(at: metadata.url)
            let destination = stringFlag("--to", in: args).map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(
                        metadata.url.deletingPathExtension().lastPathComponent + ".py"
                    )
            try PythonExporter.script(for: workflow)
                .write(to: destination, atomically: true, encoding: .utf8)
            return ["status": "exported", "path": destination.path]
        } catch {
            return self.error(error.localizedDescription)
        }
    }

    /// Reports what Phantom can and cannot do right now. The permissions
    /// answer here is about *this* process; the app bundle is granted
    /// separately, which is exactly the distinction that confuses people.
    private static func doctor() -> [String: Any] {
        let ping = ControlSocket.send(ControlSocket.Request(command: "ping"), timeout: 2)
        let bundle = appBundleURL()

        return [
            "status": "ok",
            "app_bundle": bundle?.path ?? "not found",
            "app_running": ping != nil,
            "app_accessibility": ping?.accessibility ?? false,
            "app_screen_recording": ping?.screenRecording ?? false,
            "control_socket": FileManager.default.fileExists(atPath: ControlSocket.socketURL.path),
            "workflows_directory": WorkflowStore.defaultDirectory.path,
            "workflow_count": WorkflowStore.shared.list().count,
            "this_process_accessibility": Permissions.canCreateEventTap(),
            "this_process_screen_recording": Permissions.hasScreenRecording(),
            "note": "Recording and playback run inside Phantom.app, which needs its "
                + "own Accessibility grant. This CLI only needs it if you check here.",
        ]
    }

    // MARK: - App handoff

    private static func sendLaunchingIfNeeded(
        _ request: ControlSocket.Request
    ) -> ControlSocket.Response? {
        if let response = ControlSocket.send(request) { return response }
        guard let url = appBundleURL() else { return nil }

        NSWorkspace.shared.open(url)
        guard waitForSocket(timeout: 15) else { return nil }
        return ControlSocket.send(request)
    }

    private static func waitForSocket(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ControlSocket.send(ControlSocket.Request(command: "ping"), timeout: 1) != nil {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// Finds Phantom.app: the bundle we are running from, or an installed copy.
    private static func appBundleURL() -> URL? {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" { return bundle }

        let candidates = [
            URL(fileURLWithPath: "/Applications/Phantom.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Phantom.app"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/Phantom.app"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Formatting

    private static func describe(_ metadata: WorkflowMetadata) -> [String: Any] {
        [
            "name": metadata.name,
            "filename": metadata.filename,
            "date": metadata.dateText,
            "resolution": metadata.resolution,
            "actions": metadata.actions,
            "duration": metadata.duration,
            "format": metadata.format.rawValue,
        ]
    }

    private static func describe(_ event: PhantomEvent) -> String {
        String(format: "%7.2fs  %@", event.t, event.displayText)
    }

    private static func dictionary(from response: ControlSocket.Response,
                                   extra: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["status": response.status]
        if let message = response.message { result["message"] = message }
        if let workflow = response.workflow { result["workflow"] = workflow }
        if let progress = response.progress { result["progress"] = progress }
        if let current = response.current { result["current"] = current }
        if let total = response.total { result["total"] = total }
        if let iteration = response.iteration { result["iteration"] = iteration }
        if let accessibility = response.accessibility { result["accessibility"] = accessibility }
        if let screen = response.screenRecording { result["screen_recording"] = screen }
        result.merge(extra) { existing, _ in existing }
        return result
    }

    private static func error(_ message: String) -> [String: Any] {
        ["status": "error", "message": message]
    }

    private static func emit(_ result: [String: Any], pretty: Bool) {
        if pretty { printHumanReadable(result) }
        let options: JSONSerialization.WritingOptions = pretty
            ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: options) {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    private static func printHumanReadable(_ result: [String: Any]) {
        if let workflows = result["workflows"] as? [[String: Any]] {
            if workflows.isEmpty {
                print("No workflows found.\n")
            } else {
                print("\(workflows.count) workflow(s):\n")
                for workflow in workflows {
                    let name = workflow["name"] as? String ?? "?"
                    let actions = workflow["actions"] as? Int ?? 0
                    let duration = workflow["duration"] as? Double ?? 0
                    let filename = workflow["filename"] as? String ?? ""
                    let legacy = (workflow["format"] as? String) == "python" ? " [py]" : ""
                    let padded = name.count >= 28
                        ? String(name.prefix(27)) + "…"
                        : name.padding(toLength: 28, withPad: " ", startingAt: 0)
                    print("  \(padded) "
                          + String(format: "%5d actions  %6.1fs  ", actions, duration)
                          + filename + legacy)
                }
                print("")
            }
        }
        if let events = result["events"] as? [String] {
            for line in events { print(line) }
            print("")
        }
    }

    private static func printUsage() {
        print("""
        Phantom — record and replay input on macOS

        USAGE
          phantom <command> [options] [--pretty]

        WORKFLOWS
          list                          List saved workflows
          inspect <workflow>            Print a workflow's events
          rename <workflow> <name>      Rename a workflow
          delete <workflow>             Delete a workflow
          convert <workflow>            Rewrite a legacy .py workflow as .phantom
          export <workflow> [--to P]    Write a standalone Python script

        PLAYBACK  (handled by the running app, which holds the permissions)
          run <workflow> [--speed N] [--loop N] [--loop-delay N]
                         [--skip-resolution] [--skip-windows]
          stop                          Stop the running workflow
          status                        Report playback state

        RECORDING
          record                        Open Phantom and start the record prompt

        DIAGNOSTICS
          doctor                        Report permissions, paths, and app state

        A workflow can be named by filename, exact name, or partial name.
        """)
    }

    // MARK: - Flags

    private static func stringFlag(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func doubleFlag(_ name: String, in args: [String]) -> Double? {
        stringFlag(name, in: args).flatMap(Double.init)
    }

    private static func intFlag(_ name: String, in args: [String]) -> Int? {
        stringFlag(name, in: args).flatMap(Int.init)
    }
}
