import CryptoKit
import Foundation

enum CredentialRecordAuthenticationError: Error, Equatable, LocalizedError {
    case missingAuthentication
    case invalidAuthentication

    var errorDescription: String? {
        "Credential storage could not be authenticated. Access was refused."
    }
}

/// Authenticates the record identity, authorization state and every encrypted
/// field together. AES-GCM protects field bytes; this separate, domain-derived
/// MAC prevents valid ciphertext from being relocated or its policy rewritten.
enum CredentialRecordAuthentication {
    private static let version: UInt8 = 1

    static func seal(_ record: CredentialRecord, using vaultKey: SymmetricKey) throws -> CredentialRecord {
        var record = record
        let tag = HMAC<SHA256>.authenticationCode(
            for: try authenticatedBytes(record), using: authenticationKey(vaultKey)
        )
        record.authenticationTag = Data([version]) + Data(tag)
        return record
    }

    static func verify(_ record: CredentialRecord, using vaultKey: SymmetricKey) throws {
        guard let tag = record.authenticationTag else {
            throw CredentialRecordAuthenticationError.missingAuthentication
        }
        guard tag.count == 33, tag.first == version,
              HMAC<SHA256>.isValidAuthenticationCode(
                Data(tag.dropFirst()), authenticating: try authenticatedBytes(record),
                using: authenticationKey(vaultKey)
              ) else {
            throw CredentialRecordAuthenticationError.invalidAuthentication
        }
    }

    private static func authenticatedBytes(_ record: CredentialRecord) throws -> Data {
        var record = record
        record.authenticationTag = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data("AskKey credential record v1\0".utf8) + (try encoder.encode(record))
    }

    private static func authenticationKey(_ vaultKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: vaultKey,
            salt: Data(),
            info: Data("AskKey credential authentication v1".utf8),
            outputByteCount: 32
        )
    }
}
