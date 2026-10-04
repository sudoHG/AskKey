import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct FrozenSettingsPage: View {
    @Environment(VaultViewModel.self) private var vault
    @State private var showingErase = false
    @State private var eraseWord = ""
    @State private var confirmingReadAuthenticationDisable = false
    @State private var settingsScrollTarget: String?
    @State private var confirmingAccessRecordClear = false

    init(
        initialReadAuthenticationConfirmation: Bool = false,
        initialEraseConfirmation: Bool = false,
        initialAccessRecordClearConfirmation: Bool = false
    ) {
        _confirmingReadAuthenticationDisable = State(
            initialValue: initialReadAuthenticationConfirmation
        )
        _showingErase = State(initialValue: initialEraseConfirmation)
        _eraseWord = State(initialValue: FrozenEraseConfirmationPresentation.initialText)
        _confirmingAccessRecordClear = State(initialValue: initialAccessRecordClearConfirmation)
        _settingsScrollTarget = State(initialValue: initialEraseConfirmation
            ? "settings-erase"
            : nil)
    }

    var body: some View {
        let _ = AppLanguage.store.resolved
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(appLocalized("Settings")).font(Theme.Fonts.title)
                    Text(appLocalized("Tighter security applies immediately. Relaxing it explains the impact and verifies you first."))
                        .font(Theme.Fonts.secondary).foregroundStyle(Theme.textSecondary)
                }
                settingCard(appLocalized("Agent Access"), vault.isAgentAccessPaused ? appLocalized("Paused: new requests and temporary deliveries are stopped.") : appLocalized("Running: Agents can request credentials according to each permission.")) {
                    Button(vault.isAgentAccessPaused ? appLocalized("Resume Agent Access") : appLocalized("Pause Agent Access")) {
                        Task { vault.isAgentAccessPaused ? await vault.resumeAgentAccess() : await vault.pauseAgentAccess() }
                    }
                    .foregroundStyle(vault.isAgentAccessPaused ? Theme.accent : Theme.warning)
                    .tint(vault.isAgentAccessPaused ? Theme.accent : Theme.warning)
                }
                let readAuthentication = FrozenReadAuthenticationPresentation(
                    enabled: vault.readApprovalAuthenticationEnabled,
                    confirmingDisable: confirmingReadAuthenticationDisable
                )
                settingCard(appLocalized("Require System Authentication for Reads"), appLocalized("On by default. After Allow, Touch ID confirms it is really you.")) {
                    Button(readAuthentication.actionTitle) {
                        if vault.readApprovalAuthenticationEnabled {
                            confirmingReadAuthenticationDisable = true
                        } else {
                            vault.readApprovalAuthenticationEnabled = true
                        }
                    }
                    .accessibilityIdentifier("settings-read-auth-action")
                }
                if let warning = readAuthentication.warning,
                   let confirmationTitle = readAuthentication.confirmationTitle {
                    HStack(alignment: .top, spacing: 10) {
                        Text("⚠︎").foregroundStyle(Theme.warning)
                        Text(warning)
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button(confirmationTitle, role: .destructive) {
                            Task {
                                guard await vault.confirmDeviceOwner(
                                    reason: ManagementAuthenticationAction.disableReadAuthentication.reasonKey
                                ) != nil else { return }
                                vault.readApprovalAuthenticationEnabled = false
                                confirmingReadAuthenticationDisable = false
                            }
                        }
                        Button(appLocalized("Cancel")) { confirmingReadAuthenticationDisable = false }
                    }
                    .padding(Theme.Spacing.md)
                    .background(Theme.warningSubtle, in: .rect(cornerRadius: 9))
                }
                settingCard(
                    appLocalized("Default Timed Allow"),
                    FrozenTimedAllowanceSettingsPresentation.help(
                        minutes: vault.defaultTimedAllowanceMinutes
                    )
                ) {
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { vault.timedAllowanceEnabled },
                            set: { vault.timedAllowanceEnabled = $0 }
                        )).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                        if vault.timedAllowanceEnabled {
                            Picker("", selection: Binding(
                                get: {
                                    FrozenTimedAllowanceSettingsPresentation.sanitized(
                                        vault.defaultTimedAllowanceMinutes
                                    )
                                },
                                set: { vault.defaultTimedAllowanceMinutes = $0 }
                            )) {
                                ForEach(
                                    FrozenTimedAllowanceSettingsPresentation.menuChoices(
                                        current: vault.defaultTimedAllowanceMinutes
                                    ),
                                    id: \.self
                                ) { minutes in
                                    Text(FrozenTimedAllowanceSettingsPresentation.title(minutes))
                                        .tag(minutes)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 128)
                            .accessibilityIdentifier("settings-timed-allow-minutes")
                        }
                    }
                }
                settingCard(
                    appLocalized("Global Shortcut"),
                    appLocalized("Opens the Ask Key menu. Choose Off to release the system shortcut.")
                ) {
                    Picker("", selection: Binding(
                        get: { vault.hotkeyShortcutID },
                        set: { vault.hotkeyShortcutID = $0 }
                    )) {
                        ForEach(GlobalHotkeyManager.Shortcut.allOptions, id: \.id) { option in
                            Text(option.localizedName).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 128)
                    .accessibilityIdentifier("settings-hotkey-shortcut")
                }
                settingCard(appLocalized("Launch at Login"), appLocalized("Agents cannot use credentials while Ask Key is not running.")) {
                    Toggle("", isOn: Binding(get: { vault.launchAtLogin }, set: { vault.launchAtLogin = $0 }))
                        .labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
                if let warning = FrozenLoginAtStartupPresentation(
                    isEnabled: vault.launchAtLogin
                ).warning {
                    HStack(alignment: .top, spacing: 10) {
                        Text("⚠︎").foregroundStyle(Theme.warning)
                        Text(warning)
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(Theme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warningSubtle, in: .rect(cornerRadius: 9))
                }
                settingCard(appLocalized("Access Records"), appLocalizedFormat("Keeps 90 days of events, never credential contents; %lld records now.", vault.credentialAccessRecords.count)) {
                    if confirmingAccessRecordClear {
                        Button(FrozenDangerActions.recordsConfirmationTitle, role: .destructive) {
                            confirmingAccessRecordClear = false
                            Task { await vault.clearCredentialAccessRecords() }
                        }
                        .buttonStyle(FrozenDangerButtonStyle())
                        Button(appLocalized("Keep")) { confirmingAccessRecordClear = false }
                    } else {
                        Button(appLocalized("Clear Records…"), role: .destructive) {
                            confirmingAccessRecordClear = true
                        }
                        .foregroundStyle(Theme.warning)
                        .tint(Theme.warning)
                        .disabled(vault.credentialAccessRecords.isEmpty)
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text(appLocalized("General")).font(Theme.Fonts.body.weight(.semibold))
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(appLocalized("Language")).font(Theme.Fonts.secondary.weight(.semibold))
                            Text(appLocalized("The interface language changes immediately."))
                                .font(Theme.Fonts.secondary).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        FrozenSegmentedControl(
                            options: Array(zip(
                                ["system", "zh-Hans", "en"],
                                FrozenSettingsContract.languageOptions
                            )),
                            selection: Binding(
                                get: { vault.languageMode },
                                set: { vault.languageMode = $0 }
                            )
                        )
                        .frame(width: 360)
                    }
                }
                .padding(14)
                .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.neutral(0.08)))
                .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(appLocalized("Erase Local Data")).font(Theme.Fonts.body.weight(.semibold)).foregroundStyle(Theme.warning)
                            Text(appLocalized("Deletes all local credentials, groups, and records. Uninstalling Ask Key does not do this."))
                                .font(Theme.Fonts.secondary).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button(appLocalized("Erase…"), role: .destructive) { showingErase = true }
                    }
                    if showingErase {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text(FrozenEraseConfirmationPresentation.label)
                                .font(Theme.Fonts.secondary.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                            TextField(FrozenEraseConfirmationPresentation.placeholder, text: $eraseWord)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Spacer()
                            Button(appLocalized("Cancel")) {
                                showingErase = false
                                eraseWord = ""
                            }
                            Button(appLocalized("Authenticate and Erase"), role: .destructive) {
                                Task {
                                    _ = await vault.eraseLocalLibrary(
                                        confirmation: eraseWord
                                    )
                                }
                            }
                            .disabled(
                                !FrozenEraseConfirmationPresentation.accepts(eraseWord)
                            )
                        }
                    }
                }
                .padding(14)
                .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.warning.opacity(0.3)))
                .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                .id("settings-erase")
            }
            .padding(28)
        }
        .scrollPosition(id: $settingsScrollTarget, anchor: .center)
        .background(Theme.windowBackground)
        .onAppear {
            vault.reloadCredentialAccessRecords()
        }
    }

    private func settingCard<Action: View>(
        _ title: String,
        _ message: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Fonts.body.weight(.semibold))
                Text(message).font(Theme.Fonts.secondary).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            action()
        }
        .padding(14)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.neutral(0.08)))
        .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
    }


}
