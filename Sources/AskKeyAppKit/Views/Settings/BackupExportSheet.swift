import SwiftUI

/// The recovery key, shown once before the backup file is written. The person
/// re-enters its last group to continue to the save panel.
struct BackupExportSheet: View {
    @Bindable var flow: BackupExportFlow
    let onClose: () -> Void
    @FocusState private var confirmationFocused: Bool

    var body: some View {
        BackupSheetLayout(
            title: appLocalized("Save Your Recovery Key"),
            message: appLocalized("This key opens the backup file. Ask Key doesn't keep it and can't recover it. If you lose it, nobody can open this backup, not even you.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                recoveryKey
                BackupNotice(text: appLocalized("Store the key in a password manager or on paper, apart from the backup file. Anyone with both can read every credential in it, including Hidden ones and private notes."))
                CredentialFormField(appLocalized("Type the last group of the key to confirm you saved it")) {
                    TextField(appLocalized("Last group"), text: $flow.confirmation)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Fonts.mono)
                        .autocorrectionDisabled()
                        .frame(width: 120)
                        .focused($confirmationFocused)
                        .onSubmit(save)
                        .accessibilityIdentifier("backup-confirm-last-group")
                }
                if let error = flow.errorMessage {
                    BackupErrorText(text: error)
                }
            }
        } actions: {
            Spacer(minLength: 0)
            Button(appLocalized("Cancel")) {
                flow.cancel()
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("backup-export-cancel")
            Button(appLocalized("Save Backup…"), action: save)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.isConfirmed)
                .accessibilityIdentifier("backup-export-save")
        }
        .controlSize(.large)
        .onChange(of: flow.confirmation) { _, _ in flow.noteActivity() }
        .onAppear { confirmationFocused = true }
    }

    private var recoveryKey: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Text(flow.recoveryKey ?? "")
                .font(Theme.Fonts.title.monospaced())
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityLabel(flow.recoveryKey ?? "")
                .accessibilityIdentifier("backup-recovery-key")
            Spacer(minLength: 0)
            Button(appLocalized("Copy")) { flow.copyRecoveryKey() }
                .buttonStyle(.secondaryAction)
                .accessibilityIdentifier("backup-copy-recovery-key")
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.separator))
    }

    private func save() {
        guard flow.isConfirmed else { return }
        if flow.save() { onClose() }
    }
}
