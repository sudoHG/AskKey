import CryptoKit
import Foundation

public enum BackupFileError: Error, Equatable, Sendable {
    /// The recovery key does not open this file, or the file is damaged. The
    /// two cases are indistinguishable by design.
    case cannotOpen
    /// The file was written by a newer Ask Key; this version cannot read it.
    case newerFormatVersion(Int)
    /// The file opened, but its contents are refused.
    case invalidContents(BackupContentsIssue)
}

/// The `.askkeybackup` file (ADR 0012):
///
///     header  = magic "AskKeyBackup" (12 bytes) || format version (UInt16, big-endian) || salt (32 bytes)
///     payload = AES-256-GCM nonce (12 bytes) || ciphertext || tag (16 bytes)
///
/// The payload key is HKDF-SHA256 over the recovery secret, with the salt and
/// a domain-separation label. The whole header is the additional
/// authenticated data, and the plaintext is the snapshot document.
enum BackupFile {
    static let magic = Data("AskKeyBackup".utf8)
    static let formatVersion: UInt16 = 1
    static let saltByteCount = 32
    static let headerByteCount = magic.count + 2 + saltByteCount
    private static let keyLabel = Data("AskKey backup payload key".utf8)

    static func seal(_ snapshot: BackupSnapshot, recoveryKey: BackupRecoveryKey) throws -> Data {
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var header = magic
        header.append(contentsOf: [UInt8(formatVersion >> 8), UInt8(formatVersion & 0xFF)])
        header.append(salt)
        let sealed = try AES.GCM.seal(try snapshot.encoded(), using: payloadKey(recoveryKey, salt: salt),
                                      authenticating: header)
        guard let combined = sealed.combined else { throw VaultError.encryptionFailed }
        return header + combined
    }

    /// Reads the version before anything else, so a newer file is reported as
    /// newer instead of damaged; then authenticates and decodes strictly.
    static func open(_ fileBytes: Data, recoveryKey: BackupRecoveryKey) throws -> BackupSnapshot {
        let file = Data(fileBytes) // A copy indexed from zero, even when the input is a slice.
        guard file.count >= magic.count + 2, file.prefix(magic.count) == magic else {
            throw BackupFileError.cannotOpen
        }
        let version = UInt16(file[magic.count]) << 8 | UInt16(file[magic.count + 1])
        guard version >= 1 else { throw BackupFileError.cannotOpen }
        guard version <= formatVersion else { throw BackupFileError.newerFormatVersion(Int(version)) }
        guard file.count > headerByteCount else { throw BackupFileError.cannotOpen }
        let header = Data(file.prefix(headerByteCount))
        let plaintext: Data
        do {
            let sealed = try AES.GCM.SealedBox(combined: Data(file.dropFirst(headerByteCount)))
            plaintext = try AES.GCM.open(sealed, using: payloadKey(recoveryKey, salt: Data(header.suffix(saltByteCount))),
                                         authenticating: header)
        } catch {
            throw BackupFileError.cannotOpen
        }
        do {
            return try BackupSnapshot.decode(plaintext)
        } catch let issue as BackupContentsIssue {
            throw BackupFileError.invalidContents(issue)
        }
    }

    private static func payloadKey(_ recoveryKey: BackupRecoveryKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: recoveryKey.secret, salt: salt, info: keyLabel,
                               outputByteCount: 32)
    }
}
