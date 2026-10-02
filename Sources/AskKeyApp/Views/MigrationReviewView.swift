import AppKit
import SwiftUI
import AskKeyCore

struct MigrationReviewView: View {
    @Environment(VaultViewModel.self) private var vault
    @State private var acceptsPermissionReview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(appLocalized("Migrate Existing Library")).font(.title2.bold())
            Text(appLocalized("An older library or unfinished migration was found. After authentication, Ask Key will resume a confirmed migration or show a new preview for your approval."))
                .foregroundStyle(.secondary)
            if let preview = vault.migrationPreview {
                Text(appLocalizedFormat("%lld credentials in %lld groups", preview.statistics.credentials, preview.groupNames.count))
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(preview.proposals.enumerated()), id: \.offset) { _, proposal in
                            HStack {
                                Text(proposal.displayName)
                                Spacer()
                                Text(proposal.originalPermission.map { "\($0.prototypeTitle) → " } ?? "")
                                    + Text(proposal.permission.prototypeTitle)
                            }
                        }
                    }
                }
                if preview.requiresAuthorizationReview {
                    Text(appLocalized("The integrity of older permissions cannot be verified. These credentials will be migrated to Ask Every Time; you can authorize each one again afterward."))
                    Toggle(appLocalized("I confirm these permission changes"), isOn: $acceptsPermissionReview)
                }
                if !preview.canCommit {
                    Text(appLocalizedFormat("Migration is blocked by %lld duplicate-name conflicts. Your existing data is preserved.", preview.conflicts.count))
                        .foregroundStyle(.red)
                }
                HStack {
                    Button(appLocalized("Cancel Preview")) {
                        vault.migrationPreview = nil
                        acceptsPermissionReview = false
                    }
                    Button(appLocalized("Confirm and Migrate")) { Task { await vault.acceptMigration() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!preview.canCommit || (preview.requiresAuthorizationReview && !acceptsPermissionReview))
                }
            } else {
                Button(appLocalized("Authenticate and Continue")) { Task { await vault.reviewMigration() } }
                    .buttonStyle(.borderedProminent)
            }
            if vault.migrationBusy { ProgressView() }
            Spacer(minLength: 0)
        }
        .padding(32)
        .disabled(vault.migrationBusy)
        .onChange(of: vault.migrationPreview?.sourceFingerprint) { _, _ in
            acceptsPermissionReview = false
        }
        .onDisappear { vault.migrationPreview = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if !vault.migrationBusy { vault.migrationPreview = nil }
        }
    }
}
