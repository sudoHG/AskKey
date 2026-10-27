import CryptoKit
import Foundation
import GRDB

extension VaultStore {
    static let componentMetadataCompletionKey = "component_metadata_completion_v1"
    private static let completionMessage = "AskKey component metadata complete v1"

    /// Runs inside the 0003 migration transaction, including the completion
    /// marker. Failure rolls back the column, all rows and migration history.
    static func backfillComponentMetadata(_ db: Database, using key: SymmetricKey) throws {
        var failures: [String] = []
        for var record in try CredentialRecord.order(Column("id")).fetchAll(db) {
            try CredentialRecordAuthentication.verify(record, using: key)
            do {
                guard record.encryptedComponentMetadata == nil else {
                    _ = try CredentialComponentMetadata.read(from: record, using: key)
                    continue
                }
                record.encryptedComponentMetadata = try CredentialComponentMetadata(backfilling: record, using: key)
                    .encrypted(using: key)
                try CredentialRecordAuthentication.seal(record, using: key).update(db)
            } catch {
                failures.append(try VaultCrypto.decrypt(record.encryptedDisplayName, using: key))
            }
        }
        guard failures.isEmpty else {
            throw ComponentMetadataUpgradeError(reason: .backfill, credentialNames: failures)
        }
        let marker = try VaultCrypto.encrypt(completionMessage, using: key).base64EncodedString()
        try ConfigRecord(key: componentMetadataCompletionKey, value: marker).insert(db)
    }

    private static func verifyComponentMetadataCompletion(_ db: Database, using key: SymmetricKey) throws {
        guard let stored = try ConfigRecord.fetchOne(db, key: componentMetadataCompletionKey)?.value,
              let bytes = Data(base64Encoded: stored),
              (try? VaultCrypto.decrypt(bytes, using: key)) == completionMessage else {
            throw ComponentMetadataUpgradeError(reason: .integrity, credentialNames: [])
        }
        let missing = try CredentialRecord.fetchAll(db).filter { $0.encryptedComponentMetadata == nil }
        guard missing.isEmpty else {
            throw ComponentMetadataUpgradeError(reason: .integrity, credentialNames: try missing.map {
                try VaultCrypto.decrypt($0.encryptedDisplayName, using: key)
            })
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
            try db.read { try Self.verifyComponentMetadataCompletion($0, using: key) }
        } catch let issue as ComponentMetadataUpgradeError {
            componentMetadataIssue = issue
        }
    }

    func requireComponentMetadata() throws {
        if let componentMetadataIssue { throw componentMetadataIssue }
    }
}
