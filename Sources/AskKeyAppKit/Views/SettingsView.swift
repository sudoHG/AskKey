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
        .tint(Theme.accent)
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
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.warning)
            if let message = vault.brokerFailureMessage {
                Text(appLocalized(message))
                    .font(Theme.Fonts.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(appLocalized("Retry Agent access")) {
                vault.retryBrokerRecovery()
            }
            .buttonStyle(.plain)
            .font(Theme.Fonts.caption.weight(.semibold))
        }
        .padding(10)
        .background(Theme.warningSubtle)
    }

    @ViewBuilder
    private var rootContent: some View {
        switch vault.settingsEntryState {
        case .onboarding, .empty:
            prototypeShell {
                onboardingContent
            }
        case .locked:
            prototypeShell { lockedView }
        case .management:
            CredentialManagementView(
                selectedSection: $workspaceSection,
                route: $workspaceRoute
            )
            .environment(vault)
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
                },
                onChooseAnotherType: { onboardingRoute = .templateChooser }
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
                onConnectAgent: {
                    // Agent access sits behind the management lock; unlocking
                    // lands on it, and a cancelled prompt leaves the locked page.
                    workspaceSection = .agentAccess
                    workspaceRoute = .agentAccess
                    vault.unlock()
                }
            )
            .environment(vault)
        }
    }

    private func prototypeShell<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            prototypeSidebar.frame(width: WorkspaceVisualContract.sidebarWidth)
            Divider().overlay(Theme.neutralSubtle)
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
                    .fill(Theme.neutralSubtle)
                    .frame(width: 52, height: 52)
                Image(systemName: "lock.fill")
                    .font(Theme.Icon.lockedState)
                    .foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: 7) {
                Text(copy.title)
                    .font(Theme.Fonts.headline)
                    .foregroundStyle(Theme.text)
                Text(copy.message)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            Button { vault.unlock() } label: {
                Text(copy.action)
                    .font(Theme.Fonts.secondary.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 14)
                    .frame(height: Theme.controlHeight)
                    .background(Theme.accent, in: .rect(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("unlock-management")
            if let pendingMessage = copy.pendingMessage,
               let pendingAction = copy.pendingAction {
                VStack(spacing: Theme.Spacing.sm) {
                    Divider().overlay(Theme.neutral(0.08))
                    Text(pendingMessage)
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary)
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
