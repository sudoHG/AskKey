import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    public func listRecycledTextCredentials() throws -> [ManagedTextCredential] {
        try requireManagementSession()
        let key = try requireKey()
        return try store.fetchRecycledCredentials()
            .map { try managedCredential(from: $0, key: key, includeSecrets: false) }
    }

    public func restoreRecycledTextCredential(
        id: String,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        _ = try requireKey()
        try performRecycledCredentialMutation(id: id) { try store.restoreCredential(id: id) }
    }

    public func permanentlyDeleteRecycledTextCredential(
        id: String,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        _ = try requireKey()
        try performRecycledCredentialMutation(id: id) { try store.deleteRecycledCredential(id: id) }
    }

    @discardableResult
    public func purgeRecycledTextCredentials(
        olderThan now: Date,
        using authenticator: ManagementAuthenticator
    ) throws -> Int {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        _ = try requireKey()
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let removed = try store.purgeRecycledCredentials(
            deletedOnOrBefore: sharedDateFormatter.string(from: cutoff)
        )
        if removed > 0 { notifySnapshotRelevantChange() }
        return removed
    }

    @discardableResult
    public func purgeExpiredRecycledCredentials() throws -> Int {
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        let cutoff = currentDate.addingTimeInterval(-30 * 24 * 60 * 60)
        let removed = try store.purgeRecycledCredentials(
            deletedOnOrBefore: sharedDateFormatter.string(from: cutoff)
        )
        if removed > 0 { notifySnapshotRelevantChange() }
        return removed
    }

    private func performRecycledCredentialMutation(
        id: String,
        _ mutation: () throws -> Void
    ) throws {
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        try mutation()
        brokerRequests.cancelPending(credentialID: id)
        approvalRequests.cancelPending(credentialID: id)
        notifySnapshotRelevantChange()
    }
}
