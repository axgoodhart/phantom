import SwiftUI

/// Load a saved workflow, look at what it will do, and run it.
struct PlaybackPanelView: View {
    @EnvironmentObject private var state: AppState

    private var accent: Theme.Accent { Theme.playbackAccent }

    var body: some View {
        VStack(spacing: 0) {
            workflowSection
            if state.loadedWorkflow != nil {
                runSection
                previewSection
            }
        }
    }

    private var workflowSection: some View {
        PanelSection(title: "Workflow File", accent: accent) {
            PhantomButton(title: "Browse Workflows...", style: .primary, accent: accent) {
                state.refreshWorkflows()
                state.showWorkflowBrowser = true
            }
            .disabled(state.isPlaying || state.isPreviewing)

            if let workflow = state.loadedWorkflow {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(workflow.name)
                            .font(Theme.mono(12, weight: .semibold))
                            .foregroundColor(accent.muted)
                            .lineLimit(1)
                        if workflow.isLegacy {
                            Text("PYTHON")
                                .font(Theme.mono(8, weight: .semibold))
                                .foregroundColor(Theme.caution)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(Theme.caution.opacity(0.5), lineWidth: 1))
                        }
                    }
                    HStack(spacing: 16) {
                        detail("Recorded", workflow.dateText)
                        detail("Resolution", workflow.resolution)
                    }
                    HStack(spacing: 16) {
                        detail("Actions", "\(workflow.actions)")
                        detail("Duration", workflow.durationText)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: "\(label):").foregroundColor(Theme.textDim)
            Text(value).foregroundColor(Theme.textSecondary)
        }
        .font(Theme.mono(10))
    }

    private var runSection: some View {
        PanelSection(title: "Run Workflow", accent: accent) {
            SpeedRow(label: "Speed", value: $state.playbackOptions.speed, accent: accent)

            HStack(spacing: 6) {
                PhantomButton(title: "Run", style: .primary, accent: accent) {
                    state.openPlaybackOptions()
                }
                .disabled(state.isPlaying || state.isPreviewing)

                PhantomButton(title: "Stop", style: .danger, accent: accent) {
                    state.stopPlayback()
                }
                .disabled(!state.isPlaying)

                PhantomButton(title: "Unload", accent: accent) {
                    state.unloadWorkflow()
                }
                .disabled(state.isPlaying || state.isPreviewing)
            }

            if state.isPlaying {
                ProgressTrack(value: state.playbackProgress, color: accent.full, height: 4)
            }
            if !state.loopStatus.isEmpty {
                Text(state.loopStatus)
                    .font(Theme.mono(10))
                    .foregroundColor(accent.muted)
            }
            Text("Stop anytime with \(EventRecorder.stopHotkeyDescription)")
                .font(Theme.mono(9))
                .foregroundColor(Theme.textFaint)
        }
    }

    private var previewSection: some View {
        PanelSection(title: "Preview Replay", accent: accent) {
            HStack(spacing: 6) {
                PhantomButton(title: "Preview", accent: accent) {
                    state.startPreview(ofLoadedWorkflow: true)
                }
                .disabled(state.isPlaying || state.isPreviewing)

                PhantomButton(title: "Stop", accent: accent) {
                    state.stopPreview()
                }
                .disabled(!state.isPreviewing)
            }
            if state.isPreviewing {
                ProgressTrack(value: state.previewProgress, color: Theme.info)
            }
        }
    }
}
