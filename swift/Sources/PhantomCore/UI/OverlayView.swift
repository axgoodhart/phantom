import SwiftUI

/// The full-screen, click-through layer: a cursor indicator, click ripples,
/// key popups, the reference grid, and the pre-recording prompt.
struct OverlayView: View {
    let windowFrame: CGRect

    @EnvironmentObject private var overlay: OverlayState
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            if overlay.gridVisible { grid }
            ForEach(overlay.scrollHints) { hint in
                ScrollHintView(isDown: hint.isDown).position(local(hint.point))
            }
            ForEach(overlay.ripples) { ripple in
                RippleView().position(local(ripple.point))
            }
            if overlay.cursorVisible { cursor }
            if !overlay.keyPopups.isEmpty { keyPopupStack }
            if overlay.promptVisible { prompt }
            if let value = overlay.countdownValue { countdown(value) }
        }
        .ignoresSafeArea()
    }

    /// Global input coordinates into this window's view space.
    private func local(_ point: CGPoint) -> CGPoint {
        Coordinates.viewPoint(fromGlobal: point, in: windowFrame)
    }

    // MARK: - Cursor

    private var cursor: some View {
        Circle()
            .fill(Color.black)
            .overlay(Circle().strokeBorder(
                overlay.cursorClicking ? Theme.recordAccent.full : Color(hex: 0x0073FF),
                lineWidth: 2
            ))
            .frame(width: 24, height: 24)
            .scaleEffect(overlay.cursorClicking ? 1.8 : 1)
            .shadow(color: (overlay.cursorClicking ? Theme.recordAccent.full : Color(hex: 0x03E6FF))
                .opacity(0.8), radius: overlay.cursorClicking ? 12 : 8)
            .position(local(overlay.cursorPoint))
            .animation(.linear(duration: 0.016), value: overlay.cursorPoint)
            .animation(.easeOut(duration: 0.12), value: overlay.cursorClicking)
    }

    // MARK: - Grid

    private var grid: some View {
        Canvas { context, size in
            let step = max(10, overlay.gridSize)
            let color = Theme.recordAccent.full.opacity(0.25)

            var x: CGFloat = 0
            while x <= size.width {
                context.fill(Path(CGRect(x: x, y: 0, width: 1.5, height: size.height)),
                             with: .color(color))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1.5)),
                             with: .color(color))
                y += step
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Key popups

    private var keyPopupStack: some View {
        VStack {
            Spacer()
            ZStack {
                ForEach(overlay.keyPopups) { popup in
                    KeyPopupView(label: popup.label)
                }
            }
            .padding(.bottom, windowFrame.height * 0.2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: - Countdown

    private func countdown(_ value: Int) -> some View {
        Text(verbatim: "\(value)")
            .font(Theme.display(82))
            .foregroundColor(Theme.danger)
            .frame(width: 120, height: 120)
            .background(Color.black.opacity(0.62))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.recordAccent.full.opacity(0.35), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.scale.combined(with: .opacity))
            .id(value)
            .allowsHitTesting(false)
    }

    // MARK: - Record prompt

    private var prompt: some View {
        ZStack {
            Color.black.opacity(0.36)
            RecordPromptView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pieces

private struct RippleView: View {
    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(expanded ? Color(hex: 0x003CFF) : Theme.recordAccent.full, lineWidth: 2)
            .frame(width: 24, height: 24)
            .scaleEffect(expanded ? 3 : 1)
            .opacity(expanded ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 0.5)) { expanded = true }
            }
            .allowsHitTesting(false)
    }
}

private struct ScrollHintView: View {
    let isDown: Bool
    @State private var faded = false

    var body: some View {
        Image(systemName: isDown ? "arrow.down" : "arrow.up")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(Theme.recordAccent.full)
            .opacity(faded ? 0 : 0.9)
            .onAppear { withAnimation(.easeOut(duration: 0.3)) { faded = true } }
            .allowsHitTesting(false)
    }
}

private struct KeyPopupView: View {
    let label: String
    @State private var appeared = false

    var body: some View {
        Text(glyph)
            .font(Theme.display(48))
            .foregroundColor(Color(hex: 0xF2F2F2))
            .frame(width: 94, height: 94)
            .background(Color(hex: 0x0C0C0C).opacity(0.58))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .scaleEffect(appeared ? 1 : 0.42)
            .opacity(appeared ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 0.42)) { appeared = true }
            }
            .allowsHitTesting(false)
    }

    /// Modifier and navigation keys read better as their Mac glyphs.
    private var glyph: String {
        let glyphs: [String: String] = [
            "space": "␣", "return": "↩", "enter": "↩", "tab": "⇥",
            "delete": "⌫", "fwddel": "⌦", "esc": "⎋", "escape": "⎋",
            "capslock": "⇪", "shift": "⇧", "cmd": "⌘", "command": "⌘",
            "ctrl": "⌃", "control": "⌃", "option": "⌥", "alt": "⌥",
            "up": "↑", "down": "↓", "left": "←", "right": "→",
        ]
        let normalised = label.lowercased()
        if let glyph = glyphs[normalised] { return glyph }
        if label.count == 1 { return label.uppercased() }
        return String(label.prefix(2)).uppercased()
    }
}

/// The options prompt shown before capture begins.
private struct RecordPromptView: View {
    @EnvironmentObject private var overlay: OverlayState
    @EnvironmentObject private var state: AppState

    private var accent: Theme.Accent { Theme.recordAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recording Options")
                .font(Theme.mono(15))
                .kerning(0.4)
                .foregroundColor(accent.full)
                .padding(.bottom, 8)

            Text("Choose what to capture, then press SPACE or BEGIN. While recording, "
                 + "the panel collapses into a small chip — stop anytime with "
                 + EventRecorder.stopHotkeyDescription
                 + " (Control-Option-Command-Escape).")
                .font(Theme.mono(11))
                .foregroundColor(Color(hex: 0xA0A0A0))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)

            PhantomCheckbox(label: "Record display resolution",
                            isOn: $overlay.promptRecordResolution, accent: accent)
                .padding(.vertical, 3)
            PhantomCheckbox(label: "Record window arrangement",
                            isOn: $overlay.promptRecordWindows, accent: accent)
                .padding(.vertical, 3)

            Text("⚠ Keystrokes are captured and saved as readable text in the workflow "
                 + "file. Avoid typing passwords or other secrets while recording.")
                .font(Theme.mono(10))
                .foregroundColor(Color(hex: 0xC9A24B))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            if !overlay.promptMessage.isEmpty {
                Text(overlay.promptMessage)
                    .font(Theme.mono(10))
                    .foregroundColor(overlay.promptIsError ? Color(hex: 0xFF6B7A) : Color(hex: 0x8F8F8F))
                    .padding(.top, 10)
            }

            HStack(spacing: 8) {
                Spacer()
                promptButton("Cancel", primary: false) { state.cancelRecordingPrompt() }
                promptButton("BEGIN", primary: true) { state.confirmRecordingPrompt() }
            }
            .padding(.top, 12)
        }
        .padding(16)
        .frame(width: 420)
        .background(Color(hex: 0x080808).opacity(0.97))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color(hex: 0x252525), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
    }

    private func promptButton(_ title: String, primary: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.mono(11))
                .kerning(0.6)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundColor(primary ? accent.full : Color(hex: 0xBBBBBB))
                .background(Color(hex: 0x111111))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(primary ? accent.full : Theme.borderStrong, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(overlay.promptBusy)
        .opacity(overlay.promptBusy ? 0.5 : 1)
    }
}
