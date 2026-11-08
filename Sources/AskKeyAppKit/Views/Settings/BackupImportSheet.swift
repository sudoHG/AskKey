import SwiftUI

/// The import flow after the open panel: recovery key, preview, result.
struct BackupImportSheet: View {
    @Bindable var flow: BackupImportFlow
    let onClose: () -> Void
    @FocusState private var keyFocused: Bool

    var body: some View {
        Group {
            switch flow.stage {
            case .enteringKey: keyEntry
            case .preview: preview
            case .result: result
            }
        }
        .controlSize(.large)
        .interactiveDismissDisabled()
    }

    // MARK: Recovery key

    private var keyEntry: some View {
        BackupSheetLayout(
            title: appLocalized("Enter Recovery Key"),
            message: appLocalizedFormat("Enter the recovery key for “%@”. Ask Key showed it when the backup was made and never stored it.", flow.fileName)
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                TextField(appLocalized("Recovery key"), text: $flow.recoveryKey)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Fonts.mono)
                    .autocorrectionDisabled()
                    .focused($keyFocused)
                    .onSubmit { flow.openBackup() }
                    .accessibilityIdentifier("backup-import-recovery-key")
                if let message = flow.keyMessage ?? flow.errorMessage {
                    BackupErrorText(text: message)
                }
            }
        } actions: {
            Spacer(minLength: 0)
            cancelButton
            Button(appLocalized("Continue")) { flow.openBackup() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(flow.recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("backup-import-continue")
        }
        .onAppear { keyFocused = true }
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        if let plan = flow.plan {
            BackupSheetLayout(
                title: appLocalized("Review Import"),
                message: appLocalizedFormat("“%1$@”, made %2$@.", flow.fileName, BackupImportCopy.date(plan.backupCreatedAt))
            ) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if flow.planWasRefreshed {
                        BackupNotice(
                            text: appLocalized("Your library changed after the last preview, so nothing was imported. Review this updated preview."),
                            isWarning: false
                        )
                        .accessibilityIdentifier("backup-import-refreshed")
                    }
                    BackupImportPreviewContent(plan: plan)
                    if let error = flow.errorMessage {
                        BackupErrorText(text: error)
                    }
                }
            } actions: {
                Button(appLocalized("Back")) { flow.editRecoveryKey() }
                    .disabled(flow.isWorking)
                    .accessibilityIdentifier("backup-import-back")
                Spacer(minLength: 0)
                if flow.hasNothingToImport {
                    Button(appLocalized("Done")) {
                        flow.cancel()
                        onClose()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("backup-import-done")
                } else {
                    cancelButton
                    Button(appLocalized("Authenticate and Import")) {
                        Task { await flow.confirm() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.isWorking)
                    .accessibilityIdentifier("backup-import-confirm")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("backup-import-preview")
        }
    }

    // MARK: Result

    @ViewBuilder
    private var result: some View {
        if let result = flow.result {
            BackupSheetLayout(
                title: appLocalized("Import Complete"),
                message: BackupImportCopy.resultSummary(result)
            ) {
                BackupImportResultContent(result: result)
            } actions: {
                Spacer(minLength: 0)
                Button(appLocalized("Done")) {
                    flow.finish()
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("backup-import-done")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("backup-import-result")
        }
    }

    private var cancelButton: some View {
        Button(appLocalized("Cancel")) {
            flow.cancel()
            onClose()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(flow.isWorking)
        .accessibilityIdentifier("backup-import-cancel")
    }
}
