import CryptoKit
import Foundation

enum VaultCrypto {
    static func generateKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    static func keyToData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    static func keyFromData(_ data: Data) -> SymmetricKey {
        SymmetricKey(data: data)
    }

    static func encrypt(_ value: String, using key: SymmetricKey) throws -> Data {
        guard let data = value.data(using: .utf8) else { throw VaultError.encryptionFailed }
        return try encrypt(data, using: key)
    }

    static func encrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else {
            throw VaultError.encryptionFailed
        }
        return combined
    }

    static func decrypt(_ data: Data, using key: SymmetricKey) throws -> String {
        let decrypted = try decryptData(data, using: key)
        guard let value = String(data: decrypted, encoding: .utf8) else {
            throw VaultError.decryptionFailed
        }
        return value
    }

    static func decryptData(_ data: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: key)
    }
}
