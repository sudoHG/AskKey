import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    /// Caller owns the agent-operation or final-authorization gate. Metadata only.
    func groupAllowanceSnapshot(for record: CredentialRecord, key: SymmetricKey) throws -> BrokerGroupAllowanceSnapshot? {
        guard let encryptedGroup = record.encryptedGroupName else { return nil }
        let group = try VaultCrypto.decrypt(encryptedGroup, using: key)
        let now = Date()
        let members = try store.fetchAllCredentials().compactMap { candidate -> BrokerGroupAllowanceSnapshot.Member? in
            guard let permission = CredentialPermission(rawValue: candidate.permission), permission != .hidden,
                  let encrypted = candidate.encryptedGroupName,
                  try VaultCrypto.decrypt(encrypted, using: key) == group else { return nil }
            let expiry = try candidate.expiresAt.map { try parseExpiry($0) }
            guard expiry.map({ $0 > now }) ?? true else { return nil }
            let metadata = try CredentialComponentMetadata.read(from: candidate, using: key)
            return .init(credentialID: candidate.id,
                         name: try VaultCrypto.decrypt(candidate.encryptedDisplayName, using: key),
                         metadataDigest: try RuntimeReadApprovalBinding.metadataDigest(metadata), expiresAt: expiry)
        }.sorted { $0.name == $1.name ? $0.credentialID < $1.credentialID : $0.name < $1.name }
        guard members.contains(where: { $0.credentialID == record.id }) else { return nil }
        return .init(groupName: group, members: members)
    }

    func revalidateGroupAllowance(requestID: String, capability: String) throws {
        guard let pending = approvalRequests.pendingRequests().first(where: {
            $0.requestID == requestID && $0.capability == capability
        }), let snapshot = pending.groupAllowanceSnapshot else { throw BrokerApprovalError.invalidDecision }
        do {
            let key = try requireKey()
            guard let record = try store.fetchCredential(id: pending.request.credentialID),
                  let current = try groupAllowanceSnapshot(for: record, key: key),
                  current.groupName == snapshot.groupName,
                  snapshot.members.allSatisfy({ current.members.contains($0) }) else {
                throw BrokerApprovalError.invalidDecision
            }
        } catch {
            approvalRequests.withdrawGroupAllowance(requestID: requestID, capability: capability)
            throw error
        }
    }
}
