import AppKit
import SwiftUI

struct VaultPopover: View {
    @Environment(VaultViewModel.self) private var vault
    let onOpenManagement: () -> Void

    var body: some View {
        let _ = AppLanguage.store.resolved
        VStack(spacing: 0) {
            AgentAccessPolicyNotice(showsResumeAction: false, usesCompactRecoveryMessage: true)
            if let message = vault.errorMessage {
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.warning)
                    Text(displayedUserMessage(message))
                        .font(Theme.Fonts.caption)
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
                .background(Theme.warningSubtle)
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
                vault.errorMessage = nil
                NotificationCenter.default.post(name: .presentNextAgentApproval, object: nil)
                if vault.errorMessage == nil { closePopover() }
            }
            Divider().padding(.horizontal, 10)
            if vault.componentMetadataFailure != nil {
                menuEntry(appLocalized("Review credential metadata"), systemImage: "exclamationmark.triangle") {
                    openManageWindow()
                }
            } else {
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
            }
            if vault.brokerRecoveryAvailable {
                menuEntry(appLocalized("Retry Agent access"), systemImage: "arrow.clockwise") {
                    vault.retryBrokerRecovery()
                }
            }
            Divider().padding(.horizontal, 10)
            checkForUpdatesEntry
            menuEntry(appLocalized("Quit Ask Key"), systemImage: "power") {
                closePopover()
                NSApp.terminate(nil)
            }
            .accessibilityIdentifier("menubar-quit")
        }
        .padding(.vertical, Theme.Spacing.sm)
        .frame(width: 260)
        .background(.ultraThinMaterial)
        .environment(\.locale, vault.appLocale)
        .preferredColorScheme(vault.colorScheme)
        .onAppear { vault.refreshAgentAccessPauseState() }
    }

    /// Only the official Release install has an updater (ADR 0011). Like the
    /// right-click menu item, the row is disabled while a check or an update
    /// is already in progress.
    @ViewBuilder
    private var checkForUpdatesEntry: some View {
        if let updates = vault.softwareUpdates {
            menuEntry(appLocalized("Check for Updates…"), systemImage: "arrow.triangle.2.circlepath") {
                closePopover()
                updates.checkForUpdates()
            }
            .disabled(!updates.canCheckForUpdates)
            .accessibilityIdentifier("menubar-check-for-updates")
        }
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
                    Text("\(count)").foregroundStyle(Theme.textSecondary)
                }
            }
            .font(Theme.Fonts.body)
            .padding(.horizontal, Theme.Spacing.md)
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
