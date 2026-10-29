import AppKit
import CoreGraphics
import Foundation

/// Captures the state of the screen at recording time: resolution, where
/// every visible window sits, and which app is in front.
public enum ScreenEnvironment {

    /// Windows owned by these processes are ours and never part of a recording.
    private static let ignoredOwners: Set<String> = ["Phantom", "Python", "phantom"]

    public static func capture(includeWindows: Bool = true) -> EnvironmentSnapshot {
        let size = mainDisplayResolution()
        let windows = includeWindows ? visibleWindows() : []
        return EnvironmentSnapshot(
            width: Int(size.width),
            height: Int(size.height),
            windows: windows,
            frontmostApp: frontmostApp(),
            displayCount: max(1, NSScreen.screens.count),
            windowNamesAvailable: windowNamesAvailable(windows)
        )
    }

    /// Logical resolution of the main display, matching the coordinate space
    /// that mouse events are reported in.
    public static func mainDisplayResolution() -> CGSize {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        if bounds.width > 0, bounds.height > 0 {
            return CGSize(width: bounds.width.rounded(), height: bounds.height.rounded())
        }
        if let screen = NSScreen.screens.first {
            return screen.frame.size
        }
        return CGSize(width: 1920, height: 1080)
    }

    /// Full bounds of the desktop across every display, in the global
    /// top-left coordinate space the overlay window has to cover.
    public static func desktopBounds() -> CGRect {
        var rect = CGRect.null
        for screen in NSScreen.screens {
            rect = rect.union(screen.frame)
        }
        return rect.isNull ? CGRect(origin: .zero, size: mainDisplayResolution()) : rect
    }

    public static func frontmostApp() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
    }

    /// Every on-screen window big enough to matter, in front-to-back order.
    public static func visibleWindows() -> [WindowSnapshot] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var result: [WindowSnapshot] = []
        for info in raw {
            // Layer 0 is the normal window layer; anything else is menu bar,
            // Dock, or another system element we should not move.
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            let width = Int(bounds.width)
            let height = Int(bounds.height)
            guard width >= 50, height >= 50 else { continue }

            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            guard !owner.isEmpty, !ignoredOwners.contains(owner) else { continue }

            let title = info[kCGWindowName as String] as? String ?? ""
            result.append(WindowSnapshot(
                app: owner,
                name: title.isEmpty ? "Untitled" : title,
                x: Int(bounds.origin.x),
                y: Int(bounds.origin.y),
                w: width,
                h: height
            ))
        }
        return result
    }

    private static func windowNamesAvailable(_ windows: [WindowSnapshot]) -> Bool {
        guard !windows.isEmpty else { return true }
        return windows.contains { $0.name != "Untitled" && !$0.name.isEmpty }
    }

    /// Whether Phantom can read other apps' window titles. Without Screen
    /// Recording permission macOS redacts them and window restore has to
    /// fall back to positioning each app's front window.
    public static func canReadWindowTitles() -> Bool {
        windowNamesAvailable(visibleWindows())
    }
}
