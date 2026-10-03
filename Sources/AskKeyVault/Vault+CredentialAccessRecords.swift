import Foundation
import CryptoKit

extension Vault {
    private static let accessRecordFailureKey = "credential_access_record_write_failed"

    public func recordCredentialAccess(_ event: CredentialAccessEvent) {
        do {
            let key = try requireKey()
            try purgeExpiredCredentialAccessRecords(key: key)
            let plaintext = try JSONEncoder().encode(event)
            let encrypted = try VaultCrypto.encrypt(plaintext, using: key)
            try store.insertCredentialAccessRecord(
                .init(id: UUID().uuidString, encryptedRecord: encrypted),
                capacity: CredentialAccessRecordPolicy.maximumEntries
            )
            try store.setConfigValue(key: Self.accessRecordFailureKey, value: nil)
            setAccessRecordWriteFailed(false)
        } catch {
            setAccessRecordWriteFailed(true)
            do {
                try store.setConfigValue(key: Self.accessRecordFailureKey, value: "true")
            } catch {
                NSLog("Ask Key could not persist the access-record failure flag.")
            }
        }
    }

    public func recordHiddenCredentialGuess(callerHint: String?, declaredPurpose: String?) {
        recordCredentialAccess(.init(
            timestamp: currentDate,
            credentialID: nil,
            operation: .catalog,
            result: .hiddenNameRejected,
            callerHint: callerHint,
            declaredPurpose: declaredPurpose
        ))
    }

    public func listCredentialAccessRecords() throws -> [CredentialAccessEvent] {
        try requireManagementSession()
        let key = try requireKey()
        try purgeExpiredCredentialAccessRecords(key: key)
        return try store.fetchCredentialAccessRecords().map {
            let plaintext = try VaultCrypto.decryptData($0.encryptedRecord, using: key)
            return try JSONDecoder().decode(CredentialAccessEvent.self, from: plaintext)
        }
    }

    public func clearCredentialAccessRecords(using authenticator: ManagementAuthenticator) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: "Clear Ask Key access records")
        try store.deleteAllCredentialAccessRecords()
    }

    public func hasCredentialAccessRecordWriteFailure() throws -> Bool {
        try requireManagementSession()
        if accessRecordWriteFailed { return true }
        return try store.configValue(key: Self.accessRecordFailureKey) == "true"
    }

    private func purgeExpiredCredentialAccessRecords(key: SymmetricKey) throws {
        let cutoff = currentDate.addingTimeInterval(-CredentialAccessRecordPolicy.retention)
        let expiredIDs = try store.fetchCredentialAccessRecords().compactMap { record -> String? in
            let plaintext = try VaultCrypto.decryptData(record.encryptedRecord, using: key)
            let event = try JSONDecoder().decode(CredentialAccessEvent.self, from: plaintext)
            return event.timestamp < cutoff ? record.id : nil
        }
        try store.deleteCredentialAccessRecords(ids: expiredIDs)
    }
}
