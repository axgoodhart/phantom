import AppKit
import ApplicationServices
import Foundation

/// Puts windows back where they were when the workflow was recorded.
///
/// The Python version shelled out to `osascript` once per window, paying a
/// process launch and an Apple Event round trip each time. This talks to the
/// Accessibility API directly — the same permission Phantom already needs to
/// record — so it is faster and does not depend on the target app having a
/// scripting dictionary.
public enum WindowRestorer {

    public struct Result: Sendable {
        public var positioned: Int
        public var failed: Int
        public var messages: [String]

        public var total: Int { positioned + failed }
    }

    /// Restores every recorded window, then brings the recorded frontmost
    /// app forward. `shouldCancel` is polled so a long restore can be aborted.
    public static func restore(
        windows: [WindowSnapshot],
        matchTitles: Bool = true,
        shouldCancel: () -> Bool = { false },
        progress: ((String) -> Void)? = nil
    ) -> Result {
        var positioned = 0
        var failed = 0
        var messages: [String] = []

        // One app can own several recorded windows; group so each app is
        // resolved once and its window list fetched once.
        let grouped = Dictionary(grouping: windows, by: \.app)

        for (appName, snapshots) in grouped {
            if shouldCancel() { break }

            guard let app = runningApplication(named: appName) else {
                failed += snapshots.count
                messages.append("\(appName) is not running")
                continue
            }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let axWindows = windowList(of: axApp), !axWindows.isEmpty else {
                failed += snapshots.count
                messages.append("No accessible windows for \(appName)")
                continue
            }

            var used = Set<Int>()
            for snapshot in snapshots {
                if shouldCancel() { break }
                progress?("\(appName) — \(snapshot.name)")

                let index = matchIndex(
                    for: snapshot, in: axWindows, matchTitles: matchTitles, used: used
                )
                guard let index else {
                    failed += 1
                    messages.append("No window matched \"\(snapshot.name)\" in \(appName)")
                    continue
                }
                used.insert(index)

                if apply(snapshot, to: axWindows[index]) {
                    positioned += 1
                } else {
                    failed += 1
                    messages.append("Could not move \(appName) — \(snapshot.name)")
                }
            }
        }

        return Result(positioned: positioned, failed: failed, messages: messages)
    }

    /// Brings an app to the front. Uses AppKit activation, which needs no
    /// Automation permission at all.
    @discardableResult
    public static func activate(appNamed name: String) -> Bool {
        guard let app = runningApplication(named: name) else { return false }
        return app.activate(options: [])
    }

    // MARK: - Lookup

    private static func runningApplication(named name: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        if let exact = apps.first(where: { $0.localizedName == name }) { return exact }
        // Fall back on the bundle name; `kCGWindowOwnerName` and
        // `localizedName` disagree for a few apps.
        return apps.first {
            $0.bundleURL?.deletingPathExtension().lastPathComponent == name
        }
    }

    private static func windowList(of axApp: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func matchIndex(
        for snapshot: WindowSnapshot,
        in windows: [AXUIElement],
        matchTitles: Bool,
        used: Set<Int>
    ) -> Int? {
        if matchTitles, snapshot.name != "Untitled", !snapshot.name.isEmpty {
            for (index, window) in windows.enumerated() where !used.contains(index) {
                if title(of: window) == snapshot.name { return index }
            }
        }
        // Titles are unavailable or none matched: fall back to the first
        // window this app has not been given yet.
        return windows.indices.first { !used.contains($0) }
    }

    private static func title(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }

    // MARK: - Mutation

    private static func apply(_ snapshot: WindowSnapshot, to window: AXUIElement) -> Bool {
        // Un-minimise first: a minimised window silently ignores moves.
        setBool(window, attribute: kAXMinimizedAttribute, value: false)

        let origin = CGPoint(x: CGFloat(snapshot.x), y: CGFloat(snapshot.y))
        let size = CGSize(width: CGFloat(snapshot.w), height: CGFloat(snapshot.h))

        let positionOK = setPosition(window, origin)
        let sizeOK = setSize(window, size)

        // Resizing can push the window off its recorded origin (a window with
        // a minimum size, for instance), so set the position again.
        if sizeOK { _ = setPosition(window, origin) }
        return positionOK && sizeOK
    }

    private static func setPosition(_ element: AXUIElement, _ point: CGPoint) -> Bool {
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXPositionAttribute as CFString, axValue
        ) == .success
    }

    private static func setSize(_ element: AXUIElement, _ size: CGSize) -> Bool {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSizeAttribute as CFString, axValue
        ) == .success
    }

    private static func setBool(_ element: AXUIElement, attribute: String, value: Bool) {
        let cfValue = value ? kCFBooleanTrue! : kCFBooleanFalse!
        AXUIElementSetAttributeValue(element, attribute as CFString, cfValue)
    }
}
