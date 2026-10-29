import SwiftUI

/// First-run permissions. Accessibility is the one that matters; Screen
/// Recording only sharpens window matching, so it is presented as optional.
struct PermissionsView: View {
    @EnvironmentObject private var state: AppState

    private var accent: Theme.Accent { Theme.accent(for: state.mode) }

    var body: some View {
        ModalCard(title: "Permissions", accent: accent) {
            Text("Phantom needs Accessibility to observe and post input events.")
                .font(Theme.mono(11))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

            row(
                title: "Accessibility",
                subtitle: "Required — record and replay input",
                granted: state.permissions.accessibility,
                request: { state.requestAccessibility() },
                pane: .accessibility
            )

            row(
                title: "Screen Recording",
                subtitle: "Optional — read window titles for precise restore",
                granted: state.permissions.screenRecording,
                request: { state.requestScreenRecording() },
                pane: .screenRecording
            )

            HStack(spacing: 6) {
                PhantomButton(title: "Check Again", style: .primary, accent: accent) {
                    state.refreshPermissions()
                }
                PhantomButton(title: "Continue Anyway", accent: accent) {
                    state.permissionsBypassed = true
                    state.showPermissionSheet = false
                    state.showToast("Continuing without permissions")
                }
            }
            .padding(.top, 6)

            Text("After granting Accessibility in System Settings, Phantom picks it "
                 + "up on its own — no relaunch needed.")
                .font(Theme.mono(9))
                .foregroundColor(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(title: String, subtitle: String, granted: Bool,
                     request: @escaping () -> Void,
                     pane: Permissions.Pane) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(granted ? accent.muted : Theme.borderStrong)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.mono(11))
                    .foregroundColor(granted ? Color(hex: 0xCCCCCC) : Theme.textSecondary)
                Text(subtitle)
                    .font(Theme.mono(9))
                    .foregroundColor(Theme.textFaint)
            }

            Spacer(minLength: 4)

            if !granted {
                smallButton("Request", primary: true, action: request)
            }
            smallButton("Settings", primary: false) { state.openSettings(pane) }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: 0x151515)).frame(height: 1)
        }
    }

    private func smallButton(_ title: String, primary: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.mono(9))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundColor(primary ? accent.muted : Theme.textSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(primary ? accent.muted : Theme.borderStrong, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
