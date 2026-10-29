import CoreGraphics
import Foundation

/// macOS virtual keycodes and the translations Phantom needs in both
/// directions: recording turns a keycode into something readable, playback
/// turns a stored keycode back into a `CGEvent`.
public enum Keymap {

    // MARK: - Virtual keycodes (Events.h / HIToolbox)

    /// Unshifted character produced by each keycode on a US layout.
    public static let charToKeycode: [Character: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D,
        "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23,
        "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A,
        ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F,
        "`": 0x32, " ": 0x31,
    ]

    /// Character produced when Shift is held with the same keycode.
    public static let shiftedCharToKeycode: [Character: CGKeyCode] = [
        "!": 0x12, "@": 0x13, "#": 0x14, "$": 0x15, "^": 0x16, "%": 0x17,
        "+": 0x18, "(": 0x19, "&": 0x1A, "_": 0x1B, "*": 0x1C, ")": 0x1D,
        "}": 0x1E, "{": 0x21, "|": 0x2A, "<": 0x2B, ">": 0x2F, "?": 0x2C,
        ":": 0x29, "\"": 0x27, "~": 0x32,
    ]

    /// Canonical names for non-character keys.
    public static let specialKeyToKeycode: [String: CGKeyCode] = [
        "enter": 0x24, "return": 0x24, "tab": 0x30, "space": 0x31,
        "backspace": 0x33, "delete": 0x33, "escape": 0x35, "esc": 0x35,
        "forward_delete": 0x75,

        "cmd": 0x37, "cmd_l": 0x37, "cmd_r": 0x36,
        "shift": 0x38, "shift_l": 0x38, "shift_r": 0x3C,
        "caps_lock": 0x39,
        "alt": 0x3A, "alt_l": 0x3A, "alt_r": 0x3D, "alt_gr": 0x3D,
        "ctrl": 0x3B, "ctrl_l": 0x3B, "ctrl_r": 0x3E,
        "fn": 0x3F,

        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,

        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
        "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "f13": 0x69, "f14": 0x6B, "f15": 0x71, "f16": 0x6A,
        "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,

        "home": 0x73, "end": 0x77, "page_up": 0x74, "page_down": 0x79,

        "num_lock": 0x47,
        "keypad_0": 0x52, "keypad_1": 0x53, "keypad_2": 0x54,
        "keypad_3": 0x55, "keypad_4": 0x56, "keypad_5": 0x57,
        "keypad_6": 0x58, "keypad_7": 0x59, "keypad_8": 0x5B,
        "keypad_9": 0x5C, "keypad_decimal": 0x41, "keypad_plus": 0x45,
        "keypad_minus": 0x4E, "keypad_multiply": 0x43, "keypad_divide": 0x4B,
        "keypad_enter": 0x4C, "keypad_equals": 0x51, "keypad_clear": 0x47,

        // Aliases the UI and legacy workflows use.
        "option": 0x3A, "control": 0x3B, "command": 0x37,
        "capslock": 0x39, "pgup": 0x74, "pgdn": 0x79,
    ]

    // MARK: - Modifier keycodes

    public static let capsLockKeycode: CGKeyCode = 0x39
    public static let escapeKeycode: CGKeyCode = 0x35

    /// Every left/right modifier keycode, used to strip dangling key-downs.
    public static let modifierKeycodes: Set<CGKeyCode> =
        [0x37, 0x36, 0x38, 0x3C, 0x3B, 0x3E, 0x3A, 0x3D]

    /// The modifier flag a given modifier keycode contributes.
    public static func modifierFlag(for keycode: CGKeyCode) -> CGEventFlags? {
        switch keycode {
        case 0x38, 0x3C: return .maskShift
        case 0x3B, 0x3E: return .maskControl
        case 0x3A, 0x3D: return .maskAlternate
        case 0x37, 0x36: return .maskCommand
        default: return nil
        }
    }

    /// Flags worth persisting; the rest are transient state we should not
    /// force onto the target app during replay.
    public static let recordedFlagMask: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand,
        .maskAlphaShift, .maskSecondaryFn,
    ]

    // MARK: - Reverse lookups

    private static let keycodeToChar: [CGKeyCode: Character] = {
        var map: [CGKeyCode: Character] = [:]
        for (ch, code) in charToKeycode where map[code] == nil { map[code] = ch }
        return map
    }()

    private static let keycodeToShiftedChar: [CGKeyCode: Character] = {
        var map: [CGKeyCode: Character] = [:]
        for (ch, code) in shiftedCharToKeycode where map[code] == nil { map[code] = ch }
        return map
    }()

    private static let keycodeToSpecialName: [CGKeyCode: String] = {
        // Dictionary order is undefined, so pin the canonical spelling for
        // every keycode that has aliases instead of letting one win at random.
        let preferred: [CGKeyCode: String] = [
            0x24: "return", 0x33: "delete", 0x35: "escape",
            0x37: "cmd", 0x38: "shift", 0x3A: "alt", 0x3B: "ctrl",
            0x39: "caps_lock", 0x74: "page_up", 0x79: "page_down",
        ]
        var map = preferred
        for (name, code) in specialKeyToKeycode where map[code] == nil { map[code] = name }
        return map
    }()

    /// Canonical name for a keycode, or nil when we have no mapping.
    public static func name(for keycode: CGKeyCode) -> String? {
        if let special = keycodeToSpecialName[keycode] { return special }
        if let ch = keycodeToChar[keycode] { return String(ch) }
        return nil
    }

    public static func keycode(forName rawName: String) -> CGKeyCode? {
        if rawName.count == 1, let ch = rawName.first {
            if let lowered = ch.lowercased().first, let code = charToKeycode[lowered] { return code }
            if let code = shiftedCharToKeycode[ch] { return code }
        }
        return specialKeyToKeycode[rawName.lowercased()]
    }

    private static let displayNames: [String: String] = [
        "space": "Space", "enter": "Return", "return": "Return",
        "tab": "Tab", "backspace": "Delete", "delete": "Delete",
        "forward_delete": "FwdDel",
        "escape": "Esc", "esc": "Esc",
        "shift": "Shift", "shift_l": "Shift", "shift_r": "R-Shift",
        "ctrl": "Ctrl", "ctrl_l": "Ctrl", "ctrl_r": "R-Ctrl",
        "alt": "Option", "alt_l": "Option", "alt_r": "R-Option", "alt_gr": "R-Option",
        "cmd": "Cmd", "cmd_l": "Cmd", "cmd_r": "R-Cmd",
        "caps_lock": "CapsLock", "capslock": "CapsLock", "fn": "Fn",
        "up": "Up", "down": "Down", "left": "Left", "right": "Right",
        "home": "Home", "end": "End", "page_up": "PgUp", "page_down": "PgDn",
    ]

    /// Human-readable label for the event log and the overlay key popup.
    public static func displayName(for keycode: CGKeyCode, shift: Bool = false) -> String {
        guard let name = name(for: keycode) else { return "VK\(keycode)" }

        if name.count == 1 {
            if shift, let shifted = keycodeToShiftedChar[keycode] { return String(shifted) }
            if shift { return name.uppercased() }
            return name
        }
        return displayNames[name] ?? name.uppercased()
    }
}
