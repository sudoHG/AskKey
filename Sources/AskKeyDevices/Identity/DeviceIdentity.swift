import CryptoKit
import Foundation

/// A device's three private keys (ADR 0013 → Device identity):
///
/// - the message key signs every message the device sends;
/// - the key-agreement key is the HPKE recipient key;
/// - the approval key signs only what the person approves (the pairing
///   confirmation in stage 2).
///
/// Shipped builds use `SecureEnclaveDeviceIdentity`; software keys exist only
/// in the test-only target `AskKeyDevicesTestSupport`.
public protocol DeviceIdentity: Sendable {
    var messagePublicKey: P256.Signing.PublicKey { get }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { get }
    var approvalPublicKey: P256.Signing.PublicKey { get }

    /// A raw 64-byte ECDSA P-256 SHA-256 signature by the message key.
    /// Throws `DeviceIdentityError.unusable` when the key no longer works.
    func signWithMessageKey(_ data: Data) throws -> Data

    /// A raw 64-byte ECDSA P-256 SHA-256 signature by the approval key. On an
    /// iPhone this is what asks for Face ID or Touch ID, with `reason` as the
    /// prompt. Throws `DeviceIdentityError`.
    func signWithApprovalKey(_ data: Data, reason: String) async throws -> Data

    /// Opens one single-shot HPKE `P256_SHA256_AES_GCM_256` ciphertext with
    /// the key-agreement key, in PSK mode when `preSharedKey` is given.
    /// Throws `DeviceIdentityError.unusable` when the key no longer works and
    /// any other error when the ciphertext does not open.
    func openHPKE(_ ciphertext: Data, encapsulatedKey: Data, info: Data,
                  preSharedKey: HPKEPreSharedKey?) throws -> Data
}

/// The HPKE pre-shared key and its identifier for PSK-mode messages.
public struct HPKEPreSharedKey: Sendable {
    public let key: SymmetricKey
    public let identifier: Data

    public init(key: SymmetricKey, identifier: Data) {
        self.key = key
        self.identifier = identifier
    }
}

public enum DeviceIdentityError: Error, Equatable, Sendable {
    /// This device has no Secure Enclave, so it cannot pair.
    case secureEnclaveUnavailable
    /// A stored key no longer works, for example after Migration Assistant
    /// or a Face ID or Touch ID enrollment change. The identity has to be
    /// reset and the device paired again.
    case unusable
    /// The person cancelled the Face ID, Touch ID or system prompt.
    case authenticationCancelled
    /// Face ID, Touch ID or the system prompt did not succeed.
    case authenticationFailed
    /// The Secure Enclave did not create a key.
    case keyCreationFailed
}

/// How one Secure Enclave key is protected. Every caller passes the
/// protection for each key explicitly; the module has no default.
public struct DeviceKeyProtection: Hashable, Sendable {
    public enum Accessibility: Hashable, Sendable {
        /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
        case afterFirstUnlockThisDeviceOnly
        /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
        case whenUnlockedThisDeviceOnly
    }

    public enum Authentication: Hashable, Sendable {
        /// `privateKeyUsage` only: no per-use authentication.
        case none
        /// `privateKeyUsage` and `biometryCurrentSet`: every use asks for the
        /// currently enrolled Face ID or Touch ID, with no passcode fallback.
        case biometryCurrentSet
    }

    public let accessibility: Accessibility
    public let authentication: Authentication

    public init(accessibility: Accessibility, authentication: Authentication) {
        self.accessibility = accessibility
        self.authentication = authentication
    }
}

/// The protection of each of the three keys, with no default for any.
public struct DeviceKeyProtections: Hashable, Sendable {
    public let message: DeviceKeyProtection
    public let agreement: DeviceKeyProtection
    public let approval: DeviceKeyProtection

    public init(message: DeviceKeyProtection, agreement: DeviceKeyProtection, approval: DeviceKeyProtection) {
        self.message = message
        self.agreement = agreement
        self.approval = approval
    }
}

/// The Secure Enclave's wrapped key blobs. Any process on the same device
/// that obtains a blob can use the key, so callers store them like the vault
/// key. The module itself stores nothing.
public struct DeviceIdentityKeyBlobs: Hashable, Sendable {
    public let message: Data
    public let agreement: Data
    public let approval: Data

    public init(message: Data, agreement: Data, approval: Data) {
        self.message = message
        self.agreement = agreement
        self.approval = approval
    }
}

extension DeviceIdentity {
    /// The compressed public keys, used to refuse cards that reuse this
    /// device's keys.
    var compressedPublicKeys: Set<Data> {
        [messagePublicKey.compressedRepresentation, agreementPublicKey.compressedRepresentation,
         approvalPublicKey.compressedRepresentation]
    }

    var deviceID: DeviceID { DeviceID(messagePublicKey: messagePublicKey) }
}
