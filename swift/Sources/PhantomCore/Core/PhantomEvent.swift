import CoreGraphics
import Foundation

/// One captured input action. This is the single event model used end to end:
/// the recorder emits it, the UI logs it, playback posts it, and it is what
/// gets encoded into a `.phantom` file.
public struct PhantomEvent: Codable, Equatable, Sendable {

    public enum Kind: String, Codable, Sendable {
        case move
        case drag
        case rightDrag = "right_drag"
        case leftDown = "left_down"
        case leftUp = "left_up"
        case rightDown = "right_down"
        case rightUp = "right_up"
        case middleDown = "middle_down"
        case middleUp = "middle_up"
        case keyDown = "key_down"
        case keyUp = "key_up"
        case scroll

        public var isMouseMotion: Bool {
            self == .move || self == .drag || self == .rightDrag
        }

        public var isMouseDown: Bool {
            self == .leftDown || self == .rightDown || self == .middleDown
        }

        public var isMouseUp: Bool {
            self == .leftUp || self == .rightUp || self == .middleUp
        }

        public var isKey: Bool { self == .keyDown || self == .keyUp }
    }

    /// Seconds since the recording started.
    public var t: Double
    public var kind: Kind

    /// Global screen position, top-left origin (mouse and scroll events).
    public var x: Int
    public var y: Int

    /// Virtual keycode (key events only).
    public var keycode: CGKeyCode?
    /// Modifier flags held at the time (key events only).
    public var flags: UInt64?
    /// Number of prior clicks in this click sequence — lets apps see a
    /// replayed double-click as a double-click.
    public var clickState: Int?
    /// Scroll deltas, in lines.
    public var dx: Int?
    public var dy: Int?
    /// Pixel-precise scroll deltas, present for trackpad and other
    /// continuous scrolling. Replaying these keeps momentum scrolls smooth.
    public var pdx: Int?
    public var pdy: Int?

    public init(t: Double, kind: Kind, x: Int = 0, y: Int = 0,
                keycode: CGKeyCode? = nil, flags: UInt64? = nil,
                clickState: Int? = nil, dx: Int? = nil, dy: Int? = nil,
                pdx: Int? = nil, pdy: Int? = nil) {
        self.t = t
        self.kind = kind
        self.x = x
        self.y = y
        self.keycode = keycode
        self.flags = flags
        self.clickState = clickState
        self.dx = dx
        self.dy = dy
        self.pdx = pdx
        self.pdy = pdy
    }

    // Short keys: a long recording is tens of thousands of events, and the
    // file is meant to stay hand-editable, so terse beats verbose here.
    private enum CodingKeys: String, CodingKey {
        case t, kind = "k", x, y, keycode = "vk", flags = "f"
        case clickState = "cs", dx, dy, pdx, pdy
    }

    public var eventFlags: CGEventFlags { CGEventFlags(rawValue: flags ?? 0) }

    public var hasShift: Bool { eventFlags.contains(.maskShift) }

    /// Label shown in the live event log.
    public var displayText: String {
        switch kind {
        case .move: return "Move (\(x), \(y))"
        case .drag: return "Drag (\(x), \(y))"
        case .rightDrag: return "R-drag (\(x), \(y))"
        case .leftDown: return "Left down (\(x), \(y))"
        case .leftUp: return "Left up (\(x), \(y))"
        case .rightDown: return "Right down (\(x), \(y))"
        case .rightUp: return "Right up (\(x), \(y))"
        case .middleDown: return "Middle down (\(x), \(y))"
        case .middleUp: return "Middle up (\(x), \(y))"
        case .keyDown: return "Key down: \(keyLabel)"
        case .keyUp: return "Key up: \(keyLabel)"
        case .scroll: return "Scroll (\(x), \(y)) dy=\(dy ?? 0)"
        }
    }

    /// Key name with its modifiers, e.g. `Cmd+S`.
    public var keyLabel: String {
        guard let keycode else { return "?" }
        let base = Keymap.displayName(for: keycode, shift: hasShift)
        guard !Keymap.modifierKeycodes.contains(keycode) else { return base }

        var parts: [String] = []
        let f = eventFlags
        if f.contains(.maskControl) { parts.append("Ctrl") }
        if f.contains(.maskAlternate) { parts.append("Option") }
        if f.contains(.maskShift) { parts.append("Shift") }
        if f.contains(.maskCommand) { parts.append("Cmd") }
        parts.append(base)
        return parts.joined(separator: "+")
    }

    /// Category used for colour-coding the event log.
    public enum Category: String, Sendable {
        case move, click, key, scroll
    }

    public var category: Category {
        switch kind {
        case .move, .drag, .rightDrag: return .move
        case .keyDown, .keyUp: return .key
        case .scroll: return .scroll
        default: return .click
        }
    }
}
