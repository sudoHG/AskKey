import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialManagementView {
    var recycleBinDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appLocalized("Recycle Bin"))
                    .font(.system(size: 20, weight: .semibold))
                Text(FrozenCollectionCopy.recycleSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            if vault.recycledCredentials.isEmpty {
                WorkspaceEmptyState(
                    title: appLocalized("Recycle Bin is empty"),
                    message: FrozenCollectionCopy.recycleEmptyMessage,
                    systemImage: "trash"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                    ForEach(vault.recycledCredentials) { credential in
                    HStack(spacing: 12) {
                        Text(RecycleBinPresentation.credentialMarker(name: credential.name))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 32, height: 32)
                            .background(Theme.brand.opacity(0.1), in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(credential.name).font(.system(size: 14, weight: .semibold))
                            HStack(spacing: 6) {
                                credentialTag(appLocalizedFormat("%lld items", max(credential.components.count, 1)))
                                credentialTag(RecycleBinPresentation.remainingDaysCopy(
                                    deletedAt: credential.deletedAt,
                                    now: Date()
                                ), accent: true)
                            }
                        }
                        Spacer()
                        Button(appLocalized("Restore")) {
                            vault.restoreRecycledCredential(credential)
                        }
                        .accessibilityIdentifier("credential-restore-\(credential.id)")
                        if permanentlyDeletingCredentialID == credential.id {
                            Button(
                                FrozenDangerActions.permanentCredentialConfirmationTitle,
                                role: .destructive
                            ) {
                                permanentlyDeletingCredentialID = nil
                                Task { await vault.permanentlyDeleteRecycledCredential(credential) }
                            }
                            .buttonStyle(FrozenDangerButtonStyle())
                            .accessibilityIdentifier("credential-permanent-delete-confirm-\(credential.id)")
                            Button(appLocalized("Keep")) { permanentlyDeletingCredentialID = nil }
                        } else {
                            Button(appLocalized("Delete Permanently…"), role: .destructive) {
                                permanentlyDeletingCredentialID = credential.id
                            }
                            .foregroundStyle(Theme.red)
                            .tint(Theme.red)
                            .accessibilityIdentifier("credential-permanent-delete-\(credential.id)")
                        }
                    }
                    .padding(12)
                    .background(Theme.panelBackground, in: .rect(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.neutral(0.08)))
                    .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                    }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
        }
        .background(Theme.windowBackground)
        .onAppear { if !previewMode { vault.reloadCredentials() } }
    }

}
