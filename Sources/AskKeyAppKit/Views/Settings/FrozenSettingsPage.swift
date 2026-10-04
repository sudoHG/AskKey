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
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                PageHeader(title: appLocalized("Settings"))
                agentAccessSection
                generalSection
                dataSection
            }
            .padding(Theme.Spacing.xxl)
        }
        .scrollPosition(id: $settingsScrollTarget, anchor: .center)
        .background(Theme.windowBackground)
        .onAppear {
            vault.reloadCredentialAccessRecords()
        }
    }

    // MARK: Agent access

    private var agentAccessSection: some View {
        let readAuthentication = FrozenReadAuthenticationPresentation(
            enabled: vault.readApprovalAuthenticationEnabled,
            confirmingDisable: confirmingReadAuthenticationDisable
        )
        return GroupedList(header: appLocalized("Agent Access")) {
            settingRow(
                appLocalized("Agent Access"),
                vault.isAgentAccessPaused
                    ? appLocalized("Paused: new requests and temporary deliveries are stopped.")
                    : appLocalized("Running: Agents can request credentials according to each permission.")
            ) {
                Button(vault.isAgentAccessPaused ? appLocalized("Resume") : appLocalized("Pause")) {
                    Task {
                        vault.isAgentAccessPaused
                            ? await vault.resumeAgentAccess()
                            : await vault.pauseAgentAccess()
                    }
                }
                .buttonStyle(.secondaryAction)
                .accessibilityIdentifier("settings-agent-access")
            }
            GroupedListSeparator()
            settingRow(
                appLocalized("Confirm with Touch ID after Allow"),
                appLocalized("Recommended. Turning it off requires authentication.")
            ) {
                Toggle("", isOn: Binding(
                    get: { vault.readApprovalAuthenticationEnabled },
                    set: { enabled in
                        if enabled {
                            confirmingReadAuthenticationDisable = false
                            vault.readApprovalAuthenticationEnabled = true
                        } else {
                            confirmingReadAuthenticationDisable = true
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .accessibilityIdentifier("settings-read-auth-action")
            }
            if let warning = readAuthentication.warning,
               let confirmationTitle = readAuthentication.confirmationTitle {
                GroupedListSeparator()
                confirmationRow(warning) {
                    Button(appLocalized("Cancel")) { confirmingReadAuthenticationDisable = false }
                        .buttonStyle(.secondaryAction)
                    Button(confirmationTitle, role: .destructive) {
                        Task {
                            guard await vault.confirmDeviceOwner(
                                reason: ManagementAuthenticationAction.disableReadAuthentication.reasonKey
                            ) != nil else { return }
                            vault.readApprovalAuthenticationEnabled = false
                            confirmingReadAuthenticationDisable = false
                        }
                    }
                    .buttonStyle(FrozenDangerButtonStyle())
                }
            }
            GroupedListSeparator()
            settingRow(
                appLocalized("Default Timed Allow"),
                appLocalized("When you approve, you can choose not to be asked again for this long.")
            ) {
                Picker("", selection: Binding(
                    get: {
                        vault.timedAllowanceEnabled
                            ? FrozenTimedAllowanceSettingsPresentation.sanitized(
                                vault.defaultTimedAllowanceMinutes
                            )
                            : FrozenTimedAllowanceSettingsPresentation.offTag
                    },
                    set: { minutes in
                        if minutes == FrozenTimedAllowanceSettingsPresentation.offTag {
                            vault.timedAllowanceEnabled = false
                        } else {
                            vault.defaultTimedAllowanceMinutes = minutes
                            vault.timedAllowanceEnabled = true
                        }
                    }
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
                    Divider()
                    Text(appLocalized("Off"))
                        .tag(FrozenTimedAllowanceSettingsPresentation.offTag)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings-timed-allow-minutes")
            }
        }
    }

    // MARK: General

    private var generalSection: some View {
        let loginWarning = FrozenLoginAtStartupPresentation(isEnabled: vault.launchAtLogin).warning
        return GroupedList(header: appLocalized("General")) {
            settingRow(
                appLocalized("Launch at Login"),
                loginWarning ?? appLocalized("Agents cannot use credentials while Ask Key is not running."),
                emphasizesMessage: loginWarning != nil
            ) {
                Toggle("", isOn: Binding(get: { vault.launchAtLogin }, set: { vault.launchAtLogin = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
            }
            GroupedListSeparator()
            settingRow(appLocalized("Global Shortcut"), appLocalized("Opens the Ask Key menu.")) {
                Picker("", selection: Binding(
                    get: { vault.hotkeyShortcutID },
                    set: { vault.hotkeyShortcutID = $0 }
                )) {
                    ForEach(GlobalHotkeyManager.Shortcut.allOptions, id: \.id) { option in
                        Text(option.localizedName).tag(option.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings-hotkey-shortcut")
            }
            GroupedListSeparator()
            settingRow(appLocalized("Language"), nil) {
                Picker("", selection: Binding(
                    get: { vault.languageMode },
                    set: { vault.languageMode = $0 }
                )) {
                    ForEach(
                        Array(zip(AppLanguage.publishedModes, FrozenSettingsContract.languageOptions)),
                        id: \.0
                    ) { mode, title in
                        Text(title).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings-language")
            }
        }
    }

    // MARK: Data

    private var dataSection: some View {
        GroupedList(header: appLocalized("Data")) {
            settingRow(
                appLocalized("Access Records"),
                appLocalizedFormat("Kept for 90 days. Records now: %lld.", vault.credentialAccessRecords.count)
            ) {
                if confirmingAccessRecordClear {
                    HStack(spacing: Theme.Spacing.sm) {
                        Button(appLocalized("Keep")) { confirmingAccessRecordClear = false }
                            .buttonStyle(.secondaryAction)
                        Button(FrozenDangerActions.recordsConfirmationTitle, role: .destructive) {
                            confirmingAccessRecordClear = false
                            Task { await vault.clearCredentialAccessRecords() }
                        }
                        .buttonStyle(FrozenDangerButtonStyle())
                    }
                } else {
                    Button(appLocalized("Clear Records…")) {
                        confirmingAccessRecordClear = true
                    }
                    .buttonStyle(.secondaryAction)
                    .disabled(vault.credentialAccessRecords.isEmpty)
                }
            }
            GroupedListSeparator()
            VStack(alignment: .leading, spacing: 0) {
                settingRow(
                    appLocalized("Erase Local Data"),
                    appLocalized("Permanently deletes all credentials, groups and records. This cannot be undone.")
                ) {
                    Button(appLocalized("Erase…"), role: .destructive) { showingErase = true }
                        .buttonStyle(.irreversibleAction)
                        .disabled(showingErase)
                }
                if showingErase {
                    GroupedListSeparator()
                    eraseConfirmation
                }
            }
            .id("settings-erase")
        }
    }

    private var eraseConfirmation: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(FrozenEraseConfirmationPresentation.label)
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: Theme.Spacing.sm) {
                TextField(FrozenEraseConfirmationPresentation.placeholder, text: $eraseWord)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Fonts.mono)
                    .frame(maxWidth: 200)
                Spacer()
                Button(appLocalized("Cancel")) {
                    showingErase = false
                    eraseWord = ""
                }
                .buttonStyle(.secondaryAction)
                Button(appLocalized("Authenticate and Erase"), role: .destructive) {
                    Task {
                        _ = await vault.eraseLocalLibrary(
                            confirmation: eraseWord
                        )
                    }
                }
                .buttonStyle(FrozenDangerButtonStyle())
                .disabled(
                    !FrozenEraseConfirmationPresentation.accepts(eraseWord)
                )
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: Rows

    private func settingRow<Control: View>(
        _ title: String,
        _ message: String?,
        emphasizesMessage: Bool = false,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.text)
                if let message {
                    Text(message)
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(emphasizesMessage ? Theme.warning : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Spacing.md)
            control()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .frame(minHeight: 44)
    }

    private func confirmationRow<Actions: View>(
        _ warning: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.warning)
            Text(warning)
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.md)
            actions()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.warningSubtle)
    }
}
