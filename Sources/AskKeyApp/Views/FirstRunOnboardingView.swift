import SwiftUI

struct FirstRunOnboardingView: View {
    var onCreateCredential: () -> Void
    var onImportCredential: () -> Void
    var onRestoreBackup: () -> Void

    @Environment(VaultViewModel.self) private var vault
    @State private var launchAtLoginEnabled = true
    private let hasExplicitLoginChoice: Bool

    init(
        onCreateCredential: @escaping () -> Void,
        onImportCredential: @escaping () -> Void,
        initialLaunchAtLoginEnabled: Bool? = nil,
        onRestoreBackup: @escaping () -> Void = {}
    ) {
        self.hasExplicitLoginChoice = initialLaunchAtLoginEnabled != nil
        self.onCreateCredential = onCreateCredential
        self.onImportCredential = onImportCredential
        self.onRestoreBackup = onRestoreBackup
        let launchAtLoginEnabled: Bool
        if let initialLaunchAtLoginEnabled {
            launchAtLoginEnabled = initialLaunchAtLoginEnabled
        } else {
#if DEBUG
            launchAtLoginEnabled = ProcessInfo.processInfo.environment["ASKKEY_VISUAL_PROOF_ROUTE"]
                != "welcome-login-off"
#else
            launchAtLoginEnabled = true
#endif
        }
        _launchAtLoginEnabled = State(initialValue: launchAtLoginEnabled)
    }

    private var copy: WorkspaceVisualContract.WelcomeCopy {
        WorkspaceVisualContract.welcomeCopy(
            language: AppLanguage.resolve(mode: vault.languageMode)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(vault.hasCompletedOnboarding ? appLocalized("No Credentials Yet") : copy.title)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(vault.hasCompletedOnboarding ? appLocalized("Create or import a credential to keep the materials your Agent needs together.") : copy.message)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: 440, alignment: .leading)
                }
                .padding(.top, 34)

                if vault.onboardingCredentialCount > 0 {
                    Text(appLocalizedFormat("%lld credentials are protected. Start using Ask Key to unlock management.", vault.onboardingCredentialCount))
                        .font(.system(size: 14)).padding(.vertical, 22)
                } else {
                HStack(spacing: 12) {
                    onboardingAction(
                        title: copy.createAction,
                        message: appLocalized("Save access keys, login details, certificates, or a combination of them."),
                        action: onCreateCredential
                    )
                    onboardingAction(
                        title: copy.importAction,
                        message: appLocalized("Import a regular file or .env; the original file is not modified."),
                        action: onImportCredential
                    )
                }
                .padding(.vertical, 22)
                Button(appLocalized("Restore from iCloud Backup…"), action: onRestoreBackup)
                    .buttonStyle(.link)
                    .accessibilityIdentifier("onboarding-restore-backup")
                    .padding(.bottom, 22)
                }

                if !vault.hasCompletedOnboarding {
                HStack(alignment: .top, spacing: 10) {
                    knowledgeCard(
                        appLocalized("One credential can contain multiple items"),
                        appLocalized("Keep text and files together and deliver them under one approval.")
                    )
                    knowledgeCard(
                        appLocalized("Decide Agent requests immediately"),
                        appLocalized(FrozenWelcomeCopy.agentRequestMessageKey))
                    knowledgeCard(
                        appLocalized("Ask Key runs in the background"),
                        appLocalized(FrozenWelcomeCopy.backgroundMessageKey))
                }

                HStack(alignment: .center, spacing: 18) {
                    LaunchAtLoginToggle(isOn: $launchAtLoginEnabled)
                    Spacer()
                    Button(appLocalized(vault.onboardingCredentialCount > 0 ? "Start Using" : "Create First Credential")) {
                        if vault.onboardingCredentialCount > 0 {
                            vault.completeOnboarding(enableLaunchAtLogin: launchAtLoginEnabled)
                        } else {
                            onCreateCredential()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .controlSize(.large)
                }
                .padding(.top, 22)
                }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBackground)
        .environment(\.locale, vault.appLocale)
        .accessibilityIdentifier("first-run-onboarding")
        .onAppear {
            if !hasExplicitLoginChoice && !AppRuntimeState.visualProofEnabled {
                launchAtLoginEnabled = vault.onboardingLaunchAtLoginEnabled
            }
        }
        .onChange(of: launchAtLoginEnabled) { _, value in
            vault.onboardingLaunchAtLoginEnabled = value
        }
    }

    private func onboardingAction(
        title: String,
        message: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 14.5, weight: .semibold))
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.neutral(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func knowledgeCard(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(12)
        .background(Theme.neutral(0.035), in: .rect(cornerRadius: 10))
    }
}

struct LaunchAtLoginToggle: View {
    @Binding var isOn: Bool
    var showsDisabledWarning = false

    var body: some View {
        let presentation = FrozenLoginAtStartupPresentation(
            isEnabled: isOn,
            showsWarning: showsDisabledWarning
        )
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appLocalized("Launch at Login"))
                    Text(appLocalized(FrozenWelcomeCopy.launchAtLoginSubtitleKey))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.mint)
            if let warning = presentation.warning {
                HStack(alignment: .top, spacing: 8) {
                    Text("⚠︎").foregroundStyle(Theme.amber)
                    Text(warning)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Theme.amber.opacity(0.10), in: .rect(cornerRadius: 8))
            }
        }
    }
}

enum FrozenWelcomeCopy {
    static let agentRequestMessageKey = "A system confirmation appears when a request arrives; like Touch ID, one click and your fingerprint completes approval."
    static let backgroundMessageKey = "Launch at login is on by default; Agents cannot obtain credentials while Ask Key is not running."
    static let launchAtLoginSubtitleKey = "Help Agents always find Ask Key."
    static var agentRequestMessage: String { appLocalized(agentRequestMessageKey) }
    static var backgroundMessage: String { appLocalized(backgroundMessageKey) }
    static var launchAtLoginSubtitle: String { appLocalized(launchAtLoginSubtitleKey) }
}

struct FrozenLoginAtStartupPresentation: Equatable {
    let isEnabled: Bool
    let warning: String?

    init(isEnabled: Bool, showsWarning: Bool = true) {
        self.isEnabled = isEnabled
        warning = isEnabled || !showsWarning
            ? nil
            : appLocalized("After turning this off, Ask Key will not start when the Mac restarts, and Agents will not get any credentials.")
    }

    init(isEnabled: Bool, warning: String?) {
        self.isEnabled = isEnabled
        self.warning = warning
    }
}
