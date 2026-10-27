import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(VaultViewModel.self) private var vault
    @State private var onboardingRoute: CredentialWorkspaceRoute?
    @State var navigation = ManagementNavigation()

    var body: some View {
        let _ = AppLanguage.store.resolved
        rootContent
        .tint(Theme.accent)
        .environment(\.locale, vault.appLocale)
        .preferredColorScheme(vault.colorScheme)
        .onAppear {
            updateWindowTitle()
            navigation.applyPendingNotification(to: vault)
        }
        .onChange(of: navigation.notificationRevision) { _, _ in
            navigation.applyPendingNotification(to: vault)
        }
        .onChange(of: vault.settingsEntryState) { _, _ in
            if vault.settingsEntryState != .management { navigation.interaction.reset() }
            navigation.applyPendingNotification(to: vault)
        }
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
                selectedSection: $navigation.section,
                route: $navigation.route,
                interaction: navigation.interaction
            )
            .id(navigation.notificationRevision)
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
                    navigation.section = .agentAccess
                    navigation.route = .agentAccess
                    vault.unlock()
                }
            )
            .environment(vault)
        }
    }

    private func prototypeShell<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            prototypeSidebar.frame(width: WorkspaceVisualContract.sidebarWidth)
            Divider().overlay(Theme.neutralSubtle)
            ManagementContentColumn(content: content)
        }
    }

    private var prototypeSidebar: some View {
        CredentialWorkspaceSidebar(
            selectedSection: $navigation.section,
            route: $navigation.route,
            allowsCredentialChanges: false
        )
    }

    private var lockedView: some View {
        let copy = WorkspaceVisualContract.lockedCopy(
            language: AppLanguage.resolve(mode: vault.languageMode),
            pendingRequestCount: vault.pendingApprovalCount
        )
        return VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "lock.fill")
                .font(Theme.Icon.lockedState)
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text(copy.title)
                .font(Theme.Fonts.headline)
                .foregroundStyle(Theme.text)
            Text(copy.message)
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button(copy.action) { vault.unlock() }
                .buttonStyle(FrozenPrimaryButtonStyle())
                .accessibilityIdentifier("unlock-management")
                .padding(.top, Theme.Spacing.xs)
            if let pendingMessage = copy.pendingMessage,
               let pendingAction = copy.pendingAction {
                VStack(spacing: Theme.Spacing.sm) {
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
                    .buttonStyle(.secondaryAction)
                }
                .frame(maxWidth: 340)
                .padding(.top, Theme.Spacing.xl)
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateWindowTitle() {
        NSApp.windows.first { $0.identifier?.rawValue == "settings" }?.title = vault.brandName
    }
}
