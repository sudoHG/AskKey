import SwiftUI

/// Settings → Backup: Export Backup… and Import Backup… (ADR 0012).
struct BackupSettingsSection: View {
    @Environment(VaultViewModel.self) private var vault
    @State private var exportFlow: BackupExportFlow?
    @State private var importFlow: BackupImportFlow?
    @State private var isStartingExport = false
    @State private var savedFileName: String?

    var body: some View {
        GroupedList(header: appLocalized("Backup")) {
            BackupSettingRow(
                title: appLocalized("Export"),
                message: savedFileName.map {
                    appLocalizedFormat("Saved “%@”. Keep its recovery key somewhere else.", $0)
                } ?? appLocalized("Writes every credential, including Hidden and recycled ones, to one encrypted file.")
            ) {
                Button(appLocalized("Export Backup…"), action: startExport)
                    .buttonStyle(.secondaryAction)
                    .disabled(isStartingExport)
                    .accessibilityIdentifier("settings-export-backup")
            }
            .sheet(item: $exportFlow) { flow in
                BackupExportSheet(flow: flow) {
                    if let name = flow.savedFileName { savedFileName = name }
                    exportFlow = nil
                }
                .environment(vault)
            }
            GroupedListSeparator()
            BackupSettingRow(
                title: appLocalized("Import"),
                message: appLocalized("Adds the credentials in a backup file. Nothing in this library is deleted or overwritten.")
            ) {
                Button(appLocalized("Import Backup…"), action: startImport)
                    .buttonStyle(.secondaryAction)
                    .accessibilityIdentifier("settings-import-backup")
            }
            .sheet(item: $importFlow) { flow in
                BackupImportSheet(flow: flow) { importFlow = nil }
                    .environment(vault)
            }
        }
    }

    private func startExport() {
        guard !isStartingExport else { return }
        isStartingExport = true
        savedFileName = nil
        let flow = BackupExportFlow(vault: vault)
        Task {
            if await flow.start() { exportFlow = flow }
            isStartingExport = false
        }
    }

    private func startImport() {
        let flow = BackupImportFlow(vault: vault)
        if flow.chooseFile() { importFlow = flow }
    }
}

/// A Settings row: title and message on the left, one control on the right.
struct BackupSettingRow<Control: View>: View {
    let title: String
    let message: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.text)
                Text(message)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.md)
            control
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .frame(minHeight: 44)
    }
}
