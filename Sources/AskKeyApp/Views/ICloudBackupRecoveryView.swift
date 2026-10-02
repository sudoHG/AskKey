import SwiftUI
import AskKeyCore

struct ICloudBackupRecoveryView: View {
    @Environment(VaultViewModel.self) private var vault
    var onBack: () -> Void
    var onRestored: () -> Void
    @State private var recoveryKey = ""
    @State private var generations: [ICloudBackupGeneration] = []
    @State private var selectedGenerationID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(appLocalized("Back"), action: onBack)
                    .buttonStyle(.link)
                Text(appLocalized("Restore from iCloud Backup"))
                    .font(.system(size: 26, weight: .bold))
                Text(appLocalized("Enter your saved recovery key to inspect available backups. Restoring requires system authentication."))
                    .foregroundStyle(Theme.textMuted)
                ICloudBackupRecoveryPanel(recoveryKey: $recoveryKey, generations: $generations,
                    selectedGenerationID: $selectedGenerationID, onRestored: onRestored)
                if let message = vault.iCloudBackupStatusMessage {
                    Text(message).foregroundStyle(Theme.textMuted)
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("icloud-recovery-page")
    }
}

struct ICloudBackupRecoveryPanel: View {
    @Environment(VaultViewModel.self) private var vault
    @Binding var recoveryKey: String
    @Binding var generations: [ICloudBackupGeneration]
    @Binding var selectedGenerationID: String?
    var onRestored: () -> Void = {}
    @State private var busy = false
    @State private var confirmingTakeover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SecureField(appLocalized("Paste Recovery Key"), text: $recoveryKey)
                    .accessibilityIdentifier("icloud-recovery-key")
                Button(appLocalized("Check Backup")) {
                    generations = vault.inspectICloudBackup(recoveryKey: recoveryKey)
                    selectedGenerationID = generations.first?.id
                }
                .disabled(recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("icloud-check-backup")
            }
            if !generations.isEmpty {
                Picker(appLocalized("Choose Backup"), selection: $selectedGenerationID) {
                    ForEach(generations, id: \.id) { generation in
                        Text(generation.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .tag(Optional(generation.id))
                    }
                }
                Text(appLocalized("Restore replaces current local credentials, groups, and settings. It requires system authentication and cannot be undone."))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.red)
                Button(FrozenSettingsContract.restoreConfirmationAction, role: .destructive) {
                    guard let generationID = selectedGenerationID else { return }
                    let key = recoveryKey
                    busy = true
                    Task { @MainActor in
                        defer { busy = false }
                        if await vault.restoreICloudBackup(recoveryKey: key, generationID: generationID) != nil {
                            onRestored()
                        }
                    }
                }
                .disabled(selectedGenerationID == nil)
                .accessibilityIdentifier("icloud-restore-backup")
                if vault.hasManagementSession && !vault.isLocked {
                    if confirmingTakeover {
                        Text(appLocalized("Taking ownership uses the selected backup as the starting point for future backups from this Mac. Confirm the selected version before authenticating."))
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                        HStack {
                            Button(appLocalized("Authenticate and Take Ownership")) {
                                guard let generationID = selectedGenerationID else { return }
                                let key = recoveryKey
                                busy = true
                                Task { @MainActor in
                                    defer { busy = false }
                                    if await vault.takeOwnershipOfICloudBackup(recoveryKey: key, generationID: generationID) {
                                        confirmingTakeover = false
                                    }
                                }
                            }
                            .accessibilityIdentifier("icloud-confirm-take-ownership")
                            Button(appLocalized("Cancel")) { confirmingTakeover = false }
                        }
                    } else {
                        Button(appLocalized("Take Ownership of Future Backups…")) {
                            confirmingTakeover = true
                        }
                        .disabled(selectedGenerationID == nil)
                        .accessibilityIdentifier("icloud-take-ownership")
                    }
                }
            }
            if busy { ProgressView().controlSize(.small) }
        }
        .disabled(busy)
        .onChange(of: recoveryKey) { _, _ in
            generations = []
            selectedGenerationID = nil
            confirmingTakeover = false
        }
        .onChange(of: selectedGenerationID) { _, _ in confirmingTakeover = false }
    }
}
