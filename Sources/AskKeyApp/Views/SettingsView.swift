import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(VaultViewModel.self) private var vault
    @State private var onboardingRoute: CredentialWorkspaceRoute?
    @State private var workspaceSection: CredentialWorkspaceSection = .all
    @State private var workspaceRoute: CredentialWorkspaceRoute = .library

    var body: some View {
        let _ = AppLanguage.store.resolved
        VStack(spacing: 0) {
            if vault.brokerRecoveryAvailable {
                brokerRecoveryStrip
            }
            rootContent
        }
        .tint(Theme.brand)
        .environment(\.locale, vault.appLocale)
        .preferredColorScheme(vault.colorScheme)
        .onAppear { updateWindowTitle() }
        .onChange(of: vault.languageMode) { _, _ in updateWindowTitle() }
        .alert(appLocalized("Error"), isPresented: Binding(
            get: { vault.errorMessage != nil },
            set: { if !$0 { vault.errorMessage = nil } }
        )        ) {
            Button(appLocalized("OK")) { vault.errorMessage = nil }
        } message: {
            Text(displayedUserMessage(vault.errorMessage ?? ""))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var brokerRecoveryStrip: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.red)
            if let message = vault.brokerFailureMessage {
                Text(appLocalized(message))
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(appLocalized("Retry Agent access")) {
                vault.retryBrokerRecovery()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
        }
        .padding(10)
        .background(Theme.red.opacity(0.12))
    }

    @ViewBuilder
    private var rootContent: some View {
        if vault.migrationRequired {
            prototypeShell { MigrationReviewView().environment(vault) }
        } else {
        switch vault.settingsEntryState {
        case .onboarding, .empty:
            prototypeShell {
                if workspaceRoute == .settings {
                    ICloudBackupRecoveryView(
                        onBack: { workspaceRoute = .library },
                        onRestored: {
                            onboardingRoute = nil
                            workspaceRoute = .library
                        }
                    )
                } else {
                    onboardingContent
                }
            }
        case .locked:
            prototypeShell { lockedView }
        case .management:
            CredentialManagementView(
                selectedSection: $workspaceSection,
                route: $workspaceRoute
            )
            .environment(vault)
#if DEBUG
            .onAppear {
                DebugPressRegistry.register("sidebar-agent") {
                    workspaceSection = .agentAccess
                    workspaceRoute = .agentAccess
                }
                DebugPressRegistry.register("sidebar-settings") {
                    workspaceRoute = .settings
                }
                DebugPressRegistry.register("sidebar-records") {
                    workspaceSection = .accessRecords
                    workspaceRoute = .accessRecords
                }
            }
#endif
        }
    }

    }

    @ViewBuilder
    private var onboardingContent: some View {
        switch onboardingRoute {
        case .templateChooser:
            FrozenTemplateChooserPage(
                onBack: { onboardingRoute = nil },
                onSelect: { onboardingRoute = .editor(template: $0, credentialID: nil) }
            )
        case .editor(let template, _):
            CredentialEditorView(
                credential: nil,
                initialTemplate: template,
                onClose: {
                    vault.reloadCredentials()
                    onboardingRoute = nil
                }
            )
            .environment(vault)
        case .fileImport:
            FrozenFileImportPage(
                group: nil,
                onCancel: { onboardingRoute = nil },
                onSaved: {
                    vault.reloadCredentials()
                    onboardingRoute = nil
                }
            )
            .environment(vault)
        default:
            FirstRunOnboardingView(
                onCreateCredential: {
                    if vault.hasManagementSession || vault.beginOnboardingManagement() {
                        onboardingRoute = .templateChooser
                    }
                },
                onImportCredential: {
                    if vault.hasManagementSession || vault.beginOnboardingManagement() {
                        onboardingRoute = .fileImport
                    }
                },
                onRestoreBackup: { workspaceRoute = .settings }
            )
            .environment(vault)
        }
    }

    private func prototypeShell<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            prototypeSidebar.frame(width: WorkspaceVisualContract.sidebarWidth)
            Divider().overlay(Theme.neutral(0.06))
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.windowBackground)
        }
    }

    private var prototypeSidebar: some View {
        CredentialWorkspaceSidebar(
            selectedSection: $workspaceSection,
            route: $workspaceRoute,
            allowsCredentialChanges: false
        )
    }

    private var lockedView: some View {
        let copy = WorkspaceVisualContract.lockedCopy(
            language: AppLanguage.resolve(mode: vault.languageMode),
            credentialCount: max(vault.credentials.count, vault.onboardingCredentialCount),
            pendingRequestCount: vault.pendingApprovalCount
        )
        return VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.neutral(0.06))
                    .frame(width: 52, height: 52)
                Image(systemName: "lock.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
            }
            VStack(spacing: 7) {
                Text(copy.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(copy.message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            Button { vault.unlock() } label: {
                Text(copy.action)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: Theme.controlHeight)
                    .background(Theme.brand, in: .rect(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("unlock-management")
            if let pendingMessage = copy.pendingMessage,
               let pendingAction = copy.pendingAction {
                VStack(spacing: 8) {
                    Divider().overlay(Theme.neutral(0.08))
                    Text(pendingMessage)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                    Button(pendingAction) {
                        NotificationCenter.default.post(
                            name: .presentNextAgentApproval,
                            object: nil
                        )
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateWindowTitle() {
        NSApp.windows.first { $0.identifier?.rawValue == "settings" }?.title = vault.brandName
    }
}
