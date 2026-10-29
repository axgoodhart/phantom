import CoreGraphics
import Foundation

/// Matches the display resolution a workflow was recorded at, and puts the
/// display back afterwards.
///
/// Coordinates are only meaningful at the resolution they were captured at,
/// so this runs before any input is posted.
public enum DisplayModeMatcher {

    public enum Outcome: Equatable, Sendable {
        case alreadyMatching
        case switched(from: CGSize, to: CGSize)
        case noMatchingMode(current: CGSize, wanted: CGSize)
        case failed(String)
    }

    /// The mode active before we changed anything, so playback can restore it.
    private static var originalMode: CGDisplayMode?
    private static let lock = NSLock()

    public static func currentResolution() -> CGSize {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGSize(width: bounds.width.rounded(), height: bounds.height.rounded())
    }

    public static func match(_ wanted: CGSize) -> Outcome {
        let current = currentResolution()
        guard current != wanted else { return .alreadyMatching }

        let displayID = CGMainDisplayID()
        guard let mode = bestMode(for: displayID, target: wanted) else {
            return .noMatchingMode(current: current, wanted: wanted)
        }

        lock.withLock {
            if originalMode == nil { originalMode = CGDisplayCopyDisplayMode(displayID) }
        }

        let error = CGDisplaySetDisplayMode(displayID, mode, nil)
        guard error == .success else {
            return .failed("Display mode switch failed (code \(error.rawValue))")
        }

        // The switch is asynchronous; give the window server a moment before
        // reading bounds back.
        Thread.sleep(forTimeInterval: 1.0)
        let after = currentResolution()
        guard after == wanted else {
            return .failed("Switched mode but bounds are \(Int(after.width))x\(Int(after.height))")
        }
        return .switched(from: current, to: after)
    }

    /// Returns the display to the mode it had before `match` changed it.
    @discardableResult
    public static func restoreOriginal() -> Bool {
        let mode: CGDisplayMode? = lock.withLock {
            let stored = originalMode
            originalMode = nil
            return stored
        }
        guard let mode else { return false }

        let displayID = CGMainDisplayID()
        let target = CGSize(width: CGFloat(mode.width), height: CGFloat(mode.height))
        if currentResolution() == target { return false }

        let error = CGDisplaySetDisplayMode(displayID, mode, nil)
        return error == .success
    }

    // MARK: - Mode selection

    /// Picks the mode closest to the current one that has the requested
    /// dimensions, preferring a matching pixel geometry and refresh rate so
    /// a Retina display does not drop to a non-HiDPI mode.
    private static func bestMode(for displayID: CGDirectDisplayID, target: CGSize) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return nil
        }

        let current = CGDisplayCopyDisplayMode(displayID)
        let currentLogical = current.map { CGSize(width: $0.width, height: $0.height) }
        let currentPixel = current.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
        let currentHz = current?.refreshRate ?? 0

        var best: (score: Int, mode: CGDisplayMode)?
        for mode in modes {
            let logical = CGSize(width: mode.width, height: mode.height)
            let pixel = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
            guard logical == target || pixel == target else { continue }

            var score = 0
            if logical == currentLogical { score += 4 }
            if pixel == currentPixel { score += 4 }
            if currentHz > 0, abs(mode.refreshRate - currentHz) < 0.2 { score += 2 }
            if logical != pixel { score += 1 }   // prefer HiDPI
            if mode.refreshRate > 0 { score += 1 }
            if mode.isUsableForDesktopGUI() { score += 8 }

            if best == nil || score > best!.score {
                best = (score, mode)
            }
        }
        return best?.mode
    }
}
