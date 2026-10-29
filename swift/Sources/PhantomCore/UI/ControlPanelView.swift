import SwiftUI

/// The floating control panel: header, mode tabs, status, and whichever of
/// the two panels is active. Collapses to the recording chip while capturing.
public struct ControlPanelView: View {
    @EnvironmentObject private var state: AppState

    public init() {}

    public var body: some View {
        Group {
            if state.isChipMode {
                RecordingChipView()
            } else {
                fullPanel
            }
        }
        .background(Theme.background)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accent.muted, lineWidth: state.isChipMode ? 2 : 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(state.isChipMode ? 0.85 : 1)
        .animation(.easeInOut(duration: 0.2), value: state.isChipMode)
    }

    private var accent: Theme.Accent { Theme.accent(for: state.mode) }

    private var fullPanel: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                modeTabs
                statusBar

                ScrollView {
                    VStack(spacing: 0) {
                        if state.mode == .record {
                            RecordPanelView()
                        } else {
                            PlaybackPanelView()
                        }
                    }
                }
                .scrollIndicators(.hidden)

                footer
            }

            overlays
        }
    }

    // MARK: - Chrome

    private var header: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                Text("PHANTOM")
                    .font(Theme.display(40))
                    .foregroundStyle(wordmarkGradient)
                    .kerning(1)
                Text("RECORD  ·  REPLAY  ·  REPEAT")
                    .font(Theme.mono(9))
                    .kerning(1.3)
                    .foregroundColor(Color(hex: 0xD3D3D3))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Button {
                state.requestQuit()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.textFaint)
            .help("Quit Phantom")
            .padding(6)
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private var wordmarkGradient: LinearGradient {
        LinearGradient(
            colors: [.white, accent.full, accent.dim, .white],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var modeTabs: some View {
        HStack(spacing: 0) {
            tab("Record", mode: .record, enabled: !state.isPlaying && !state.isPreviewing)
            tab("Playback", mode: .playback, enabled: state.canSwitchToPlayback)
        }
        .background(Theme.surface)
    }

    private func tab(_ title: String, mode: AppState.Mode, enabled: Bool) -> some View {
        Button {
            state.switchMode(mode)
        } label: {
            Text(title)
                .font(Theme.mono(11, weight: .semibold))
                .textCase(.uppercase)
                .kerning(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundColor(state.mode == mode ? accent.full : Theme.textDim)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(state.mode == mode ? accent.full : .clear)
                        .frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            StatusDot(activity: state.activity, accent: accent)
            Text(state.statusText)
                .font(Theme.mono(11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if state.eventCount > 0 {
                Text(verbatim: "\(state.eventCount) events")
                    .font(Theme.mono(10))
                    .foregroundColor(accent.muted)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 8)
                    .background(Capsule().fill(accent.muted.opacity(0.12)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(accent.dim).frame(height: 1)
        }
    }

    private var footer: some View {
        Text("Phantom v2.0 — native")
            .font(Theme.mono(9))
            .foregroundColor(Theme.borderStrong)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlays: some View {
        if state.showPermissionSheet {
            ModalBackdrop { PermissionsView() }
        }
        if state.showWorkflowBrowser {
            ModalBackdrop { WorkflowBrowserView() }
        }
        if state.showPlaybackOptions {
            ModalBackdrop { PlaybackOptionsView() }
        }
        if state.showQuitConfirmation {
            ModalBackdrop {
                ModalCard(title: "Quit Phantom", accent: accent) {
                    Text(state.quitConfirmationMessage)
                        .font(Theme.mono(11))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        PhantomButton(title: "Quit", style: .danger, accent: accent) {
                            state.quit()
                        }
                        PhantomButton(title: "Stay", accent: accent) {
                            state.showQuitConfirmation = false
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        if let toast = state.toast {
            VStack {
                Spacer()
                Text(toast)
                    .font(Theme.mono(11, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 18)
                    .background(accent.full)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.bottom, 20)
                    .padding(.horizontal, 12)
                    .multilineTextAlignment(.center)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .allowsHitTesting(false)
        }
    }
}

/// The collapsed recording state: a small always-visible stop control.
struct RecordingChipView: View {
    @EnvironmentObject private var state: AppState
    @State private var pulsing = false

    var body: some View {
        Button {
            state.stopRecording()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.danger)
                    .frame(width: 10, height: 10)
                    .opacity(pulsing ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                               value: pulsing)
                Text(verbatim: "\(state.eventCount) events")
                    .font(Theme.mono(12))
                    .foregroundColor(Theme.text)
                Spacer(minLength: 4)
                Text(verbatim: "\(EventRecorder.stopHotkeyDescription) stop")
                    .font(Theme.mono(11))
                    .foregroundColor(Theme.textDim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Stop recording")
        .onAppear { pulsing = true }
    }
}
