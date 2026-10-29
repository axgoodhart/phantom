import Combine
import CoreGraphics
import Foundation

/// What the transparent full-screen overlay is currently showing.
///
/// The Python build drove this by evaluating JavaScript strings in a
/// WebView. Here it is just observable state.
@MainActor
public final class OverlayState: ObservableObject {

    public struct Ripple: Identifiable, Equatable {
        public let id = UUID()
        public var point: CGPoint
    }

    public struct KeyPopup: Identifiable, Equatable {
        public let id = UUID()
        public var label: String
    }

    public struct ScrollHint: Identifiable, Equatable {
        public let id = UUID()
        public var point: CGPoint
        public var isDown: Bool
    }

    /// Cursor indicator (shown while recording and during preview).
    @Published public var cursorVisible = false
    @Published public var cursorPoint: CGPoint = .zero
    @Published public var cursorClicking = false

    @Published public var ripples: [Ripple] = []
    @Published public var keyPopups: [KeyPopup] = []
    @Published public var scrollHints: [ScrollHint] = []

    /// Reference grid.
    @Published public var gridVisible = false
    @Published public var gridSize: CGFloat = 50

    /// Pre-recording options prompt.
    @Published public var promptVisible = false
    @Published public var promptRecordResolution = true
    @Published public var promptRecordWindows = true
    @Published public var promptBusy = false
    @Published public var promptMessage = "Press SPACE or click BEGIN to commence recording."
    @Published public var promptIsError = false
    @Published public var countdownValue: Int?

    public init() {}

    public func showCursor() { cursorVisible = true }

    public func hideCursor() {
        cursorVisible = false
        cursorClicking = false
    }

    public func moveCursor(to point: CGPoint) { cursorPoint = point }

    public func showClick(at point: CGPoint) {
        cursorPoint = point
        cursorClicking = true
        let ripple = Ripple(point: point)
        ripples.append(ripple)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self?.cursorClicking = false
        }
        expire(ripple.id, from: \.ripples, after: 500)
    }

    public func showKey(_ label: String) {
        let popup = KeyPopup(label: label)
        keyPopups.append(popup)
        expire(popup.id, from: \.keyPopups, after: 450)
    }

    public func showScroll(at point: CGPoint, isDown: Bool) {
        let hint = ScrollHint(point: point, isDown: isDown)
        scrollHints.append(hint)
        expire(hint.id, from: \.scrollHints, after: 300)
    }

    public func clearTransients() {
        ripples.removeAll()
        keyPopups.removeAll()
        scrollHints.removeAll()
    }

    private func expire<T: Identifiable>(
        _ id: T.ID,
        from keyPath: ReferenceWritableKeyPath<OverlayState, [T]>,
        after milliseconds: UInt64
    ) where T.ID: Equatable {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            self?[keyPath: keyPath].removeAll { $0.id == id }
        }
    }
}
