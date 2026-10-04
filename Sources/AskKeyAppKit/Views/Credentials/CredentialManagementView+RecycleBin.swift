import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialManagementView {
    var recycleBinDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(appLocalized("Recycle Bin"))
                    .font(Theme.Fonts.title)
                Text(FrozenCollectionCopy.recycleSubtitle)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.lg)

            if vault.recycledCredentials.isEmpty {
                WorkspaceEmptyState(
                    title: appLocalized("Recycle Bin is empty"),
                    message: FrozenCollectionCopy.recycleEmptyMessage,
                    systemImage: "trash"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Spacing.sm) {
                    ForEach(vault.recycledCredentials) { credential in
                    HStack(spacing: Theme.Spacing.md) {
                        Text(RecycleBinPresentation.credentialMarker(name: credential.name))
                            .font(Theme.Fonts.body.bold())
                            .foregroundStyle(Theme.accent)
                            .frame(width: 32, height: 32)
                            .background(Theme.accentSubtle, in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(credential.name).font(Theme.Fonts.body.weight(.semibold))
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
                            .foregroundStyle(Theme.warning)
                            .tint(Theme.warning)
                            .accessibilityIdentifier("credential-permanent-delete-\(credential.id)")
                        }
                    }
                    .padding(Theme.Spacing.md)
                    .background(Theme.surface, in: .rect(cornerRadius: 9))
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
