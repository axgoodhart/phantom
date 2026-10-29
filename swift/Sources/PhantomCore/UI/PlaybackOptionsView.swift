import SwiftUI

/// Confirmation step before a workflow starts posting real input, with the
/// per-run overrides: environment matching, speed, and looping.
struct PlaybackOptionsView: View {
    @EnvironmentObject private var state: AppState
    @State private var chimeTask: Task<Void, Never>?

    private var accent: Theme.Accent { Theme.playbackAccent }

    var body: some View {
        ModalCard(title: "Playback Options", accent: accent) {
            PhantomCheckbox(label: "Match recording's resolution",
                            isOn: $state.playbackOptions.matchResolution, accent: accent)
            PhantomCheckbox(label: "Match recording's window arrangement",
                            isOn: $state.playbackOptions.matchWindows, accent: accent)

            SpeedRow(label: "Speed", value: $state.playbackOptions.speed, accent: accent)
                .padding(.vertical, 4)

            PhantomCheckbox(label: "Play sound on completion",
                            isOn: $state.playbackOptions.playCompletionSound, accent: accent)

            Divider().overlay(Theme.border).padding(.vertical, 4)

            loopControls

            HStack(spacing: 6) {
                PhantomButton(title: "Start", style: .primary, accent: accent) {
                    chimeTask?.cancel()
                    state.startPlayback()
                }
                PhantomButton(title: "Cancel", accent: accent) {
                    chimeTask?.cancel()
                    state.showPlaybackOptions = false
                }
            }
            .padding(.top, 6)

            Text("Playback posts real input. Stop anytime with "
                 + EventRecorder.stopHotkeyDescription + ".")
                .font(Theme.mono(9))
                .foregroundColor(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: armChime)
        .onDisappear { chimeTask?.cancel() }
    }

    private var loopControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Loop")
                    .font(Theme.mono(10))
                    .foregroundColor(Theme.textDim)
                    .frame(width: 34, alignment: .leading)
                numberField(value: $state.playbackOptions.loopCount, width: 54)
                    .disabled(state.playbackOptions.loopInfinite)
                Text("times")
                    .font(Theme.mono(10))
                    .foregroundColor(Theme.textFaint)
                Spacer(minLength: 0)
                PhantomCheckbox(label: "∞", isOn: $state.playbackOptions.loopInfinite,
                                accent: accent)
                    .fixedSize()
            }

            HStack(spacing: 6) {
                Text("Delay")
                    .font(Theme.mono(10))
                    .foregroundColor(Theme.textDim)
                    .frame(width: 34, alignment: .leading)
                decimalField(value: $state.playbackOptions.loopDelay, width: 54)
                Text("sec between runs")
                    .font(Theme.mono(10))
                    .foregroundColor(Theme.textFaint)
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Text("Ping")
                    .font(Theme.mono(10))
                    .foregroundColor(Theme.textDim)
                    .frame(width: 34, alignment: .leading)
                PhantomTextField(placeholder: "URL to check between runs (optional)",
                                 text: $state.playbackOptions.pingURL,
                                 accent: accent, font: Theme.mono(10))
            }
        }
    }

    private func numberField(value: Binding<Int>, width: CGFloat) -> some View {
        TextField("", value: value, format: .number)
            .textFieldStyle(.plain)
            .font(Theme.mono(11))
            .multilineTextAlignment(.center)
            .foregroundColor(Theme.text)
            .frame(width: width)
            .padding(.vertical, 3)
            .background(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Theme.borderStrong, lineWidth: 1))
    }

    private func decimalField(value: Binding<Double>, width: CGFloat) -> some View {
        TextField("", value: value, format: .number)
            .textFieldStyle(.plain)
            .font(Theme.mono(11))
            .multilineTextAlignment(.center)
            .foregroundColor(Theme.text)
            .frame(width: width)
            .padding(.vertical, 3)
            .background(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Theme.borderStrong, lineWidth: 1))
    }

    /// The sheet can appear while the user is away from the machine. A chime
    /// after 20 seconds is a nudge, not a timeout — nothing starts on its own.
    private func armChime() {
        chimeTask?.cancel()
        chimeTask = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            Chime.play()
        }
    }
}
