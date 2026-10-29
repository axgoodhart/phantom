import AppKit
import Foundation

/// One binary, two personalities: run it with a command and it behaves like
/// a CLI; run it with none and it launches the agent app.
public enum PhantomEntry {

    @MainActor
    public static func run() -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains(where: { CommandLineInterface.commands.contains($0) })
            || arguments.contains("--help") || arguments.contains("-h") {
            CommandLineInterface.run(arguments: arguments)
        }

        runApp()
    }

    @MainActor
    private static func runApp() -> Never {
        let app = NSApplication.shared
        // Agent app: floating windows, no Dock icon, no menu bar takeover.
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        exit(0)
    }
}
