import SwiftUI

/// Everything about capturing: controls, the live event log, saving, the
/// visual preview, and the reference grid.
struct RecordPanelView: View {
    @EnvironmentObject private var state: AppState

    private var accent: Theme.Accent { Theme.recordAccent }

    var body: some View {
        VStack(spacing: 0) {
            recording
            eventLog
            save
            preview
            grid
            if let environment = state.environment {
                environmentSection(environment)
            }
        }
    }

    // MARK: - Controls

    private var recording: some View {
        PanelSection(title: "Recording", accent: accent) {
            HStack(spacing: 6) {
                PhantomButton(title: "Record", style: .danger, accent: accent) {
                    state.beginRecordingFlow()
                }
                .disabled(state.isRecording || state.isPreviewing)

                PhantomButton(title: "Stop", style: .warning, accent: accent) {
                    state.stopRecording()
                }
                .disabled(!state.isRecording)

                PhantomButton(title: "Clear", accent: accent) {
                    state.clearRecording()
                }
                .disabled(!state.hasRecording || state.isRecording)
            }
            Text("Stop anytime with \(EventRecorder.stopHotkeyDescription)")
                .font(Theme.mono(9))
                .foregroundColor(Theme.textFaint)
        }
    }

    // MARK: - Log

    private var eventLog: some View {
        PanelSection(title: "Event Log", accent: accent) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if state.log.isEmpty {
                            Text("No events recorded")
                                .font(Theme.mono(10))
                                .foregroundColor(Theme.borderStrong)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                        }
                        ForEach(state.log) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(String(format: "%.3fs", entry.time))
                                    .foregroundColor(Theme.textDim)
                                    .frame(width: 52, alignment: .leading)
                                Text(entry.text)
                                    .foregroundColor(color(for: entry.category))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(Theme.mono(10))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .id(entry.id)
                        }
                    }
                }
                .frame(height: 190)
                .onChange(of: state.log.count) { _ in
                    guard let last = state.log.last else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .background(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func color(for category: PhantomEvent.Category) -> Color {
        switch category {
        case .move: return Theme.textDim
        case .click: return Theme.clickColor
        case .key: return Theme.keyColor
        case .scroll: return Theme.scrollColor
        }
    }

    // MARK: - Save

    private var save: some View {
        PanelSection(title: "Save Workflow", accent: accent) {
            HStack(spacing: 6) {
                PhantomTextField(placeholder: "Workflow name...",
                                 text: $state.workflowName, accent: accent)
                    .disabled(!state.hasRecording)
                PhantomButton(title: "Save", style: .primary, accent: accent) {
                    state.saveRecording()
                }
                .disabled(!state.hasRecording)
                .frame(width: 76)
            }
            SpeedRow(label: "Speed", value: $state.exportSpeed, accent: accent)
                .disabled(!state.hasRecording)

            HStack(spacing: 6) {
                PhantomButton(title: "Export .py", accent: accent) {
                    exportPython()
                }
                .disabled(!state.hasRecording)
            }
            Text("Saved to ~/Library/Application Support/Phantom/workflows")
                .font(Theme.mono(9))
                .foregroundColor(Theme.textFaint)
        }
        .opacity(state.hasRecording ? 1 : 0.55)
    }

    private func exportPython() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pythonScript].compactMap { $0 }
        panel.nameFieldStringValue = (state.workflowName.isEmpty ? "workflow" : state.workflowName)
            .replacingOccurrences(of: " ", with: "_") + ".py"
        panel.title = "Export workflow as a Python script"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.exportRecordingAsPython(to: url)
    }

    // MARK: - Preview

    private var preview: some View {
        PanelSection(title: "Preview Replay", accent: accent) {
            HStack(spacing: 6) {
                PhantomButton(title: "Preview", accent: accent) {
                    state.startPreview(ofLoadedWorkflow: false)
                }
                .disabled(!state.hasRecording || state.isPreviewing || state.isRecording)

                PhantomButton(title: "Stop", accent: accent) {
                    state.stopPreview()
                }
                .disabled(!state.isPreviewing)
            }
            SpeedRow(label: "Speed", value: $state.previewSpeed, accent: accent)
                .disabled(!state.hasRecording)

            if state.isPreviewing {
                ProgressTrack(value: state.previewProgress, color: Theme.info)
            }
            Text("Draws the recording on the overlay. No input is posted.")
                .font(Theme.mono(9))
                .foregroundColor(Theme.textFaint)
        }
        .opacity(state.hasRecording ? 1 : 0.55)
    }

    // MARK: - Grid

    private var grid: some View {
        PanelSection(title: "Grid Overlay", accent: accent) {
            HStack(spacing: 10) {
                PhantomToggle(isOn: Binding(
                    get: { state.gridVisible },
                    set: { state.setGrid(visible: $0) }
                ), accent: accent)
                Text("Show Grid")
                    .font(Theme.mono(10))
                    .foregroundColor(Theme.textDim)
                Slider(
                    value: Binding(get: { state.gridSize }, set: { state.setGridSize($0) }),
                    in: 20...150,
                    step: 5
                )
                .controlSize(.mini)
                .tint(accent.muted)
                Text(verbatim: "\(Int(state.gridSize))px")
                    .font(Theme.mono(10))
                    .foregroundColor(Theme.textDim)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    // MARK: - Environment

    private func environmentSection(_ environment: EnvironmentSnapshot) -> some View {
        PanelSection(title: "Environment", accent: accent) {
            VStack(alignment: .leading, spacing: 3) {
                row("Resolution", environment.resolutionText)
                row("Windows", "\(environment.windows.count) captured")
                row("Frontmost", environment.frontmostApp)

                if environment.displayCount > 1 {
                    warning("Multiple displays: resolution matching covers the main display only")
                }
                if !environment.windows.isEmpty, !environment.windowNamesAvailable {
                    warning("Window titles unavailable — grant Screen Recording for precise matching")
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(label):")
                .foregroundColor(Theme.textDim)
            Text(value)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        }
        .font(Theme.mono(10))
    }

    private func warning(_ text: String) -> some View {
        Text("⚠ \(text)")
            .font(Theme.mono(9))
            .foregroundColor(Theme.caution)
            .fixedSize(horizontal: false, vertical: true)
    }
}

import AppKit
import UniformTypeIdentifiers

extension UTType {
    static var pythonScript: UTType? { UTType(filenameExtension: "py") }
}
