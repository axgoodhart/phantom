import SwiftUI

/// The saved workflow library, including anything left over from the Python
/// build — those entries can be converted to the native format in place.
struct WorkflowBrowserView: View {
    @EnvironmentObject private var state: AppState
    @State private var renaming: WorkflowMetadata?
    @State private var renameText = ""
    @State private var pendingDelete: WorkflowMetadata?

    private var accent: Theme.Accent { Theme.accent(for: state.mode) }

    var body: some View {
        ModalCard(title: "Workflows", accent: accent, maxWidth: 360) {
            if state.workflows.isEmpty {
                Text("No saved workflows")
                    .font(Theme.mono(10))
                    .foregroundColor(Theme.textFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(state.workflows) { workflow in
                            row(workflow)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            HStack(spacing: 6) {
                PhantomButton(title: "Load", style: .primary, accent: accent) {
                    if let selected = state.selectedWorkflow { state.loadWorkflow(selected) }
                }
                .disabled(state.selectedWorkflow == nil)

                PhantomButton(title: "Cancel", accent: accent) {
                    state.showWorkflowBrowser = false
                    state.selectedWorkflow = nil
                }
            }
            .padding(.top, 4)

            if let target = pendingDelete {
                deleteConfirmation(target)
            }
        }
        .onAppear { state.refreshWorkflows() }
    }

    private func row(_ workflow: WorkflowMetadata) -> some View {
        let selected = state.selectedWorkflow?.url == workflow.url

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if renaming?.url == workflow.url {
                    PhantomTextField(placeholder: "Name", text: $renameText, accent: accent,
                                     font: Theme.mono(11, weight: .semibold))
                        .onSubmit { commitRename(workflow) }
                } else {
                    HStack(spacing: 5) {
                        Text(workflow.name)
                            .font(Theme.mono(11, weight: .semibold))
                            .foregroundColor(selected ? accent.muted : Color(hex: 0xDDDDDD))
                            .lineLimit(1)
                        if workflow.isLegacy {
                            Text("PY")
                                .font(Theme.mono(8, weight: .semibold))
                                .foregroundColor(Theme.caution)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Text(workflow.dateText)
                    Text(verbatim: "\(workflow.actions) actions")
                    Text(workflow.durationText)
                }
                .font(Theme.mono(9))
                .foregroundColor(Color(hex: 0x666666))
            }
            Spacer(minLength: 0)

            if renaming?.url == workflow.url {
                iconButton("checkmark", tint: accent.muted) { commitRename(workflow) }
            } else {
                if workflow.isLegacy {
                    iconButton("arrow.triangle.2.circlepath", tint: Theme.caution,
                               help: "Convert to the native format") {
                        state.convertWorkflow(workflow)
                    }
                }
                iconButton("pencil", tint: Theme.textDim, help: "Rename") {
                    renaming = workflow
                    renameText = workflow.name
                }
                iconButton("xmark", tint: Theme.textDim, help: "Delete") {
                    pendingDelete = workflow
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? accent.muted.opacity(0.1) : Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(selected ? accent.muted : Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.loadWorkflow(workflow) }
        .onTapGesture { state.selectedWorkflow = workflow }
    }

    private func iconButton(_ symbol: String, tint: Color, help: String = "",
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func commitRename(_ workflow: WorkflowMetadata) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != workflow.name else { return }
        state.renameWorkflow(workflow, to: name)
    }

    private func deleteConfirmation(_ workflow: WorkflowMetadata) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delete \"\(workflow.name)\"? This cannot be undone.")
                .font(Theme.mono(10))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                PhantomButton(title: "Delete", style: .danger, accent: accent) {
                    state.deleteWorkflow(workflow)
                    pendingDelete = nil
                }
                PhantomButton(title: "Keep", accent: accent) { pendingDelete = nil }
            }
        }
        .padding(10)
        .background(Theme.field)
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Theme.danger.opacity(0.6), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
