import CryptoKit
import Foundation
import GRDB
import AskKeyBroker

extension VaultStore {
    static let componentMetadataCompletionKey = "component_metadata_completion_v2"
    static let componentMetadataLegacyCompletionKey = "component_metadata_completion_v1"
    private static let legacyCompletionMessage = "AskKey component metadata complete v1"
    private static let completionMessage = Data("AskKey component metadata complete v2\0".utf8)

    static func isWellFormedComponentMetadataCompletionMarker(_ value: String, legacy: Bool = false) -> Bool {
        guard let bytes = Data(base64Encoded: value), bytes.base64EncodedString() == value else { return false }
        guard legacy else { return bytes.count == SHA256.byteCount }
        guard bytes.count == 12 + legacyCompletionMessage.utf8.count + 16 else { return false }
        return (try? AES.GCM.SealedBox(combined: bytes)) != nil
    }

    private static func completionAuthenticationKey(_ key: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(),
            info: Data("AskKey component metadata completion authentication v2".utf8), outputByteCount: 32)
    }

    private static func insertComponentMetadataCompletion(_ db: Database, using key: SymmetricKey) throws {
        let marker = Data(HMAC<SHA256>.authenticationCode(
            for: completionMessage, using: completionAuthenticationKey(key))).base64EncodedString()
        try ConfigRecord(key: componentMetadataCompletionKey, value: marker).insert(db)
    }

    /// Runs inside the 0003 migration transaction, including the completion
    /// marker. Failure rolls back the column, all rows and migration history.
    static func backfillComponentMetadata(_ db: Database, using key: SymmetricKey) throws {
        guard try ConfigRecord.filter([componentMetadataCompletionKey, componentMetadataLegacyCompletionKey]
            .contains(Column("key"))).fetchCount(db) == 0 else {
            throw ComponentMetadataUpgradeError(reason: .integrity, credentialNames: [])
        }
        var failures: [String] = []
        for var record in try CredentialRecord.order(Column("id")).fetchAll(db) {
            try CredentialRecordAuthentication.verify(record, using: key)
            let metadata: CredentialComponentMetadata
            do {
                metadata = try record.encryptedComponentMetadata == nil
                    ? CredentialComponentMetadata(backfilling: record, using: key)
                    : CredentialComponentMetadata.read(from: record, using: key)
            } catch {
                // Only projection decode/validation is a credential problem.
                // Encryption, authentication writes and storage failures escape.
                failures.append(try VaultCrypto.decrypt(record.encryptedDisplayName, using: key))
                continue
            }
            guard record.encryptedComponentMetadata == nil else { continue }
            record.encryptedComponentMetadata = try metadata.encrypted(using: key)
            try CredentialRecordAuthentication.seal(record, using: key).update(db)
        }
        guard failures.isEmpty else {
            throw ComponentMetadataUpgradeError(reason: .backfill, credentialNames: failures)
        }
        try insertComponentMetadataCompletion(db, using: key)
    }

    /// Verification and the development-only v1 upgrade share one transaction.
    /// A partial or mixed-version state is never repaired on open.
    private static func verifyAndUpgradeComponentMetadataCompletion(_ db: Database, using key: SymmetricKey) throws {
        let current = try ConfigRecord.fetchOne(db, key: componentMetadataCompletionKey)?.value
        let legacy = try ConfigRecord.fetchOne(db, key: componentMetadataLegacyCompletionKey)?.value
        if let current, legacy == nil,
           isWellFormedComponentMetadataCompletionMarker(current), let bytes = Data(base64Encoded: current),
           HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: completionMessage,
                                                using: completionAuthenticationKey(key)) {
            // A verified v2 marker is already complete.
        } else if current == nil, let legacy,
                  isWellFormedComponentMetadataCompletionMarker(legacy, legacy: true),
                  let bytes = Data(base64Encoded: legacy),
                  (try? VaultCrypto.decrypt(bytes, using: key)) == legacyCompletionMessage {
            // Write only after the metadata-presence check below.
        } else {
            throw ComponentMetadataUpgradeError(reason: .integrity, credentialNames: [])
        }
        let missing = try CredentialRecord.fetchAll(db).filter { $0.encryptedComponentMetadata == nil }
        guard missing.isEmpty else {
            throw ComponentMetadataUpgradeError(reason: .integrity, credentialNames: try missing.map {
                try VaultCrypto.decrypt($0.encryptedDisplayName, using: key)
            })
        }
        if legacy != nil {
            try insertComponentMetadataCompletion(db, using: key)
            try ConfigRecord.deleteOne(db, key: componentMetadataLegacyCompletionKey)
        }
    }

    /// Every 0003 library must already carry a valid completion marker.
    /// Even an empty existing library never initializes a missing marker.
    func prepareComponentMetadata(using key: SymmetricKey) throws {
        guard componentMetadataIssue == nil else { return }
        do {
            let opening = try db.read(CurrentLibrarySchema.opening)
            if opening != .current {
                try migrate(componentMetadataKey: key)
                hasComponentMetadataColumn = true
            }
            try db.write { try Self.verifyAndUpgradeComponentMetadataCompletion($0, using: key) }
        } catch let issue as ComponentMetadataUpgradeError {
            componentMetadataIssue = issue
        } catch is DatabaseError {
            componentMetadataIssue = ComponentMetadataUpgradeError(reason: .storage, credentialNames: [])
        }
    }

    func requireComponentMetadata() throws {
        if componentMetadataIssue != nil { throw BrokerProviderError.agentAccessPaused }
    }
}
