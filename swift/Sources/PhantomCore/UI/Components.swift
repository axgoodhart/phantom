import SwiftUI

/// Shared building blocks for the panel: buttons, sections, sliders, and the
/// small status affordances.

// MARK: - Buttons

public struct PhantomButton: View {
    public enum Style {
        case normal
        case primary
        case danger
        case warning
    }

    let title: String
    var style: Style = .normal
    var accent: Theme.Accent
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.mono(11, weight: .medium))
                .textCase(.uppercase)
                .kerning(0.5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(background)
                .foregroundColor(foreground)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.3)
        .onHover { isHovering = $0 && isEnabled }
    }

    private var tint: Color {
        switch style {
        case .normal: return Theme.borderStrong
        case .primary: return accent.muted
        case .danger: return Theme.danger
        case .warning: return Theme.warning
        }
    }

    private var background: Color {
        guard isHovering else {
            return style == .normal ? Color(hex: 0x1E1E1E) : Color.clear
        }
        return style == .normal ? Color(hex: 0x2A2A2A) : tint
    }

    private var foreground: Color {
        switch style {
        case .normal: return isHovering ? .white : Color(hex: 0xCCCCCC)
        case .primary: return isHovering ? .black : accent.muted
        case .danger, .warning: return isHovering ? .white : tint
        }
    }

    private var borderColor: Color {
        style == .normal && !isHovering ? Theme.borderStrong : tint
    }
}

// MARK: - Layout

public struct PanelSection<Content: View>: View {
    let title: String
    var accent: Theme.Accent
    @ViewBuilder var content: () -> Content

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.mono(10, weight: .semibold))
                .textCase(.uppercase)
                .kerning(1)
                .foregroundColor(accent.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(accent.dim).frame(height: 1)
        }
    }
}

// MARK: - Controls

public struct SpeedRow: View {
    let label: String
    @Binding var value: Double
    var accent: Theme.Accent
    var range: ClosedRange<Double> = 0.25...4
    var step: Double = 0.25

    public var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Theme.mono(10))
                .foregroundColor(Theme.textDim)
                .frame(width: 40, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .controlSize(.mini)
                .tint(accent.muted)
            Text(formatted)
                .font(Theme.mono(11))
                .foregroundColor(accent.muted)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var formatted: String {
        value == value.rounded() ? "\(Int(value))x" : String(format: "%.2gx", value)
    }
}

public struct PhantomToggle: View {
    @Binding var isOn: Bool
    var accent: Theme.Accent

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? accent.muted : Theme.borderStrong)
                    .frame(width: 36, height: 20)
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .padding(.horizontal, 2)
            }
            .animation(.easeInOut(duration: 0.18), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

public struct PhantomCheckbox: View {
    let label: String
    @Binding var isOn: Bool
    var accent: Theme.Accent

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isOn ? accent.muted : Theme.borderStrong, lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isOn ? accent.muted : Color.clear)
                    )
                    .frame(width: 13, height: 13)
                    .overlay {
                        if isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.black)
                        }
                    }
                Text(label)
                    .font(Theme.mono(11))
                    .foregroundColor(Color(hex: 0xBBBBBB))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

public struct ProgressTrack: View {
    var value: Double
    var color: Color
    var height: CGFloat = 3

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * geometry.size.width)
            }
        }
        .frame(height: height)
    }
}

public struct StatusDot: View {
    var activity: AppState.Activity
    var accent: Theme.Accent
    @State private var pulsing = false

    public var body: some View {
        Circle()
            .fill(fill)
            .overlay(Circle().strokeBorder(strokeColor, lineWidth: activity == .ready ? 1 : 0))
            .frame(width: 8, height: 8)
            .opacity(shouldPulse && pulsing ? 0.3 : 1)
            .animation(
                shouldPulse
                    ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                    : .default,
                value: pulsing
            )
            .onAppear { pulsing = shouldPulse }
            .onChange(of: activity) { _ in pulsing = shouldPulse }
    }

    private var shouldPulse: Bool {
        activity == .recording || activity == .previewing || activity == .playing
    }

    private var fill: Color {
        switch activity {
        case .ready: return .clear
        case .recording: return Theme.danger
        case .stopped: return accent.muted
        case .previewing, .playing: return Theme.info
        }
    }

    private var strokeColor: Color {
        activity == .ready ? accent.full : .clear
    }
}

// MARK: - Text field

public struct PhantomTextField: View {
    let placeholder: String
    @Binding var text: String
    var accent: Theme.Accent
    var font: Font = Theme.mono(11)

    @FocusState private var focused: Bool

    public var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundColor(Theme.text)
            .focused($focused)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(focused ? accent.muted : Theme.borderStrong, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Modal chrome

public struct ModalCard<Content: View>: View {
    let title: String
    var accent: Theme.Accent
    var maxWidth: CGFloat = 320
    @ViewBuilder var content: () -> Content

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.mono(12, weight: .semibold))
                .textCase(.uppercase)
                .kerning(1)
                .foregroundColor(accent.muted)
            content()
        }
        .padding(14)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(Theme.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
    }
}

public struct ModalBackdrop<Content: View>: View {
    @ViewBuilder var content: () -> Content

    public var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            content()
                .padding(16)
        }
    }
}
