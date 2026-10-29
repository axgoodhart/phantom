import CoreGraphics
import Foundation

/// Marks the synthetic events Phantom posts during playback so its own taps
/// can tell them apart from real hardware input. Without this a recorded
/// force-stop chord would stop the very playback replaying it.
public enum PhantomEventSource {
    /// Arbitrary sentinel written into each posted event's user data field.
    public static let magic: Int64 = 0x50_48_41_4E // "PHAN"

    public static func stamp(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: magic)
    }

    public static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == magic
    }

    /// A shared event source. Reusing one keeps the modifier and click state
    /// that macOS tracks per source consistent across a replay.
    public static let shared: CGEventSource? = CGEventSource(stateID: .hidSystemState)
}
