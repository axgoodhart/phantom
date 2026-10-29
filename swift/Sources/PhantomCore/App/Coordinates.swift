import AppKit
import CoreGraphics

/// Translates between the two coordinate spaces this app lives in.
///
/// Input events use CoreGraphics global coordinates: origin at the top-left
/// of the main display, y increasing downward. AppKit windows use the
/// primary screen's bottom-left as origin with y increasing upward. Getting
/// this wrong puts the overlay cursor in the wrong half of the screen, so it
/// lives in one place.
public enum Coordinates {

    /// Height of the primary screen, the hinge both spaces rotate around.
    public static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
    }

    public static func cocoaPoint(fromGlobal point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    public static func globalPoint(fromCocoa point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// A window's frame expressed in global input coordinates, which is what
    /// the recorder's exclusion zone needs.
    public static func globalRect(fromCocoa frame: CGRect) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: primaryHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// A global input point expressed in the coordinate space of a view that
    /// fills `windowFrame`, with its origin at the top-left.
    public static func viewPoint(fromGlobal point: CGPoint, in windowFrame: CGRect) -> CGPoint {
        let windowTopInGlobal = primaryHeight - windowFrame.maxY
        return CGPoint(x: point.x - windowFrame.origin.x, y: point.y - windowTopInGlobal)
    }

    /// The rectangle covering every display, in AppKit coordinates.
    public static var desktopFrame: CGRect {
        var rect = CGRect.null
        for screen in NSScreen.screens { rect = rect.union(screen.frame) }
        return rect.isNull ? (NSScreen.main?.frame ?? .zero) : rect
    }
}
