import AppKit
import SwiftUI

struct VaultPopover: View {
    @Environment(VaultViewModel.self) private var vault
    let onOpenManagement: () -> Void

    var body: some View {
        let _ = AppLanguage.store.resolved
        VStack(spacing: 0) {
            if let message = vault.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.red)
                    Text(displayedUserMessage(message))
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        vault.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(appLocalized("Dismiss error"))
                }
                .padding(10)
                .background(Theme.red.opacity(0.12))
                Divider()
            }

            menuEntry(appLocalized("Open Ask Key"), systemImage: "macwindow") {
                openManageWindow()
            }
            .accessibilityIdentifier("menubar-open-management")
            menuEntry(
                appLocalized("Pending requests"),
                systemImage: "tray",
                count: vault.pendingApprovalCount
            ) {
                NotificationCenter.default.post(name: .presentNextAgentApproval, object: nil)
                closePopover()
            }
            Divider().padding(.horizontal, 10)
            menuEntry(
                appLocalized(vault.isAgentAccessPaused ? "Resume Agent Access" : "Pause Agent Access"),
                systemImage: vault.isAgentAccessPaused ? "play.fill" : "pause.fill"
            ) {
                Task {
                    if vault.isAgentAccessPaused {
                        await vault.resumeAgentAccess()
                    } else {
                        await vault.pauseAgentAccess()
                    }
                }
            }
            if vault.brokerRecoveryAvailable {
                menuEntry(appLocalized("Retry Agent access"), systemImage: "arrow.clockwise") {
                    vault.retryBrokerRecovery()
                }
            }
        }
        .padding(.vertical, 8)
        .frame(width: 260)
        .background(.ultraThinMaterial)
        .environment(\.locale, vault.appLocale)
        .preferredColorScheme(vault.colorScheme)
        .onAppear { vault.refreshAgentAccessPauseState() }
    }

    private func menuEntry(
        _ title: String,
        systemImage: String,
        count: Int? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).frame(width: 18)
                Text(title)
                Spacer()
                if let count {
                    Text("\(count)").foregroundStyle(Theme.textMuted)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func closePopover() {
        NSApp.windows
            .filter {
                $0.isVisible
                    && !$0.styleMask.contains(.titled)
                    && $0.identifier?.rawValue != "settings"
            }
            .forEach { $0.orderOut(nil) }
    }

    private func openManageWindow() {
        closePopover()
        onOpenManagement()
    }
}
