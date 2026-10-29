import AppKit
import SwiftUI

/// The visual language carried over from the HTML interface: black surfaces,
/// a monospace grid, and an accent that switches from green to cyan when the
/// app moves from recording to playback.
public enum Theme {

    // MARK: - Palette

    public static let background = Color.black
    public static let surface = Color(hex: 0x0A0A0A)
    public static let surfaceRaised = Color(hex: 0x0B0B0B)
    public static let field = Color(hex: 0x111111)

    public static let border = Color(hex: 0x222222)
    public static let borderStrong = Color(hex: 0x333333)

    public static let text = Color(hex: 0xE0E0E0)
    public static let textSecondary = Color(hex: 0x999999)
    public static let textDim = Color(hex: 0x808080)
    public static let textFaint = Color(hex: 0x444444)

    public static let danger = Color(hex: 0xFF3344)
    public static let warning = Color(hex: 0xFF8800)
    public static let caution = Color(hex: 0xFFAA44)
    public static let info = Color(hex: 0x4488FF)

    // Event log categories.
    public static let clickColor = Color(hex: 0xFF6688)
    public static let keyColor = Color(hex: 0x88BBFF)
    public static let scrollColor = Color(hex: 0xFFAA44)

    /// Accent trio for a mode: full, muted, and dim.
    public struct Accent {
        public var full: Color
        public var muted: Color
        public var dim: Color
    }

    public static let recordAccent = Accent(
        full: Color(hex: 0x10DF58),
        muted: Color(hex: 0x0BAB58),
        dim: Color(hex: 0x017840)
    )

    public static let playbackAccent = Accent(
        full: Color(hex: 0x00E5FF),
        muted: Color(hex: 0x44C8E0),
        dim: Color(hex: 0x05616C)
    )

    public static func accent(for mode: AppState.Mode) -> Accent {
        mode == .playback ? playbackAccent : recordAccent
    }

    // MARK: - Type

    /// The display face used for the wordmark and buttons, falling back to
    /// the monospace stack when it is not installed.
    public static let displayFontName = "Anxler"

    public static func display(_ size: CGFloat) -> Font {
        if NSFont(name: displayFontName, size: size) != nil {
            return .custom(displayFontName, size: size)
        }
        return .system(size: size, weight: .semibold, design: .monospaced)
    }

    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Menlo", size: size).weight(weight)
    }

    /// Registers bundled fonts. Safe to call more than once.
    public static func registerFonts() {
        guard let url = Resources.url(forResource: "Anxler", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

/// Finds bundled resources whether running from an app bundle or `swift run`.
public enum Resources {
    public static func url(forResource name: String, withExtension ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }

        if let override = ProcessInfo.processInfo.environment["PHANTOM_RESOURCES"] {
            let candidate = URL(fileURLWithPath: override)
                .appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }

        // Development fallback: Resources/ next to the package.
        let sourceRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UI
            .deletingLastPathComponent()   // PhantomCore
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // swift
            .appendingPathComponent("Resources/\(name).\(ext)")
        return FileManager.default.fileExists(atPath: sourceRelative.path) ? sourceRelative : nil
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
