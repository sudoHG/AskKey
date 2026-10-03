import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialManagementView {
    var accessRecordsDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appLocalized("Access records"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(FrozenAccessRecordsCopy.subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            if vault.credentialAccessRecords.isEmpty {
                WorkspaceEmptyState(
                    title: appLocalized("No Access Records Yet"),
                    message: FrozenAccessRecordsCopy.subtitle,
                    systemImage: "list.bullet.rectangle"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                    ForEach(Array(vault.credentialAccessRecords.enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .top, spacing: 14) {
                        Text(FrozenClock.string(from: event.timestamp))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 52, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(accessOperationTitle(event.operation))
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(credentialName(for: event.credentialID)) · \(event.callerHint ?? appLocalized("Local Caller"))")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        credentialTag(accessResultTitle(event.result), accent: event.result == .allowed)
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
        .onAppear { if !previewMode { vault.reloadCredentialAccessRecords() } }
    }

    private func accessOperationTitle(_ operation: CredentialAccessEvent.Operation) -> String {
        switch operation {
        case .catalog: return appLocalized("Browse Credential Catalog")
        case .runtimeRead: return appLocalized("Use Credential")
        case .create: return appLocalized("Create Credential")
        case .modify: return appLocalized("Modify Credential")
        case .delete: return appLocalized("Delete Credential")
        }
    }

    private func accessResultTitle(_ result: CredentialAccessEvent.Result) -> String {
        switch result {
        case .allowed: return appLocalized("Allowed")
        case .denied: return appLocalized("Denied")
        case .failed: return appLocalized("Failed")
        case .hiddenNameRejected: return appLocalized("Hidden")
        }
    }

    private func credentialName(for id: String?) -> String {
        guard let id else { return appLocalized("Hidden credential request") }
        return vault.credentials.first { $0.id == id }?.name ?? id
    }

}
