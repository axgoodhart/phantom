import AppKit
import ApplicationServices
import Foundation

/// The system permissions Phantom depends on, and the prompts that request them.
public enum Permissions {

    public struct Status: Equatable, Sendable {
        /// Required: capture and post input events.
        public var accessibility: Bool
        /// Optional: read other apps' window titles, so window restore can
        /// match a specific window rather than each app's front window.
        public var screenRecording: Bool

        public var isReady: Bool { accessibility }
    }

    public static func status() -> Status {
        Status(
            accessibility: hasAccessibility(prompt: false),
            screenRecording: hasScreenRecording()
        )
    }

    // MARK: - Accessibility

    /// Trusted for Accessibility. Everything Phantom does — the event tap,
    /// posting input, moving windows through the AX API — needs this.
    public static func hasAccessibility(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        if AXIsProcessTrustedWithOptions(options as CFDictionary) { return true }
        // The trust flag can lag behind a fresh grant; the tap is the real test.
        return canCreateEventTap()
    }

    /// Creating a listen-only tap is exactly the capability recording needs,
    /// which makes it a more honest check than the trust flag alone.
    public static func canCreateEventTap() -> Bool {
        let mask: CGEventMask = 1 << CGEventMask(CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else { return false }

        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        return true
    }

    // MARK: - Screen Recording

    /// Window titles are redacted without Screen Recording permission. This
    /// is a soft dependency: restore still works, just less precisely.
    public static func hasScreenRecording() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    @discardableResult
    public static func requestScreenRecording() -> Bool {
        if #available(macOS 10.15, *) {
            return CGRequestScreenCaptureAccess()
        }
        return true
    }

    // MARK: - Settings panes

    public enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
        case automation = "Privacy_Automation"
    }

    @discardableResult
    public static func openSettings(_ pane: Pane) -> Bool {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")
        guard let url else { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// The short alert Phantom plays when a long workflow finishes.
public enum Chime {
    public static func play() {
        if let sound = NSSound(named: "Glass") ?? NSSound(named: "Ping") {
            sound.play()
            return
        }
        NSSound.beep()
    }
}
