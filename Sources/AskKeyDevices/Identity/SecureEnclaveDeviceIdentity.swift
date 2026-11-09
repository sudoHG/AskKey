import CryptoKit
import CryptoTokenKit
import Foundation
import LocalAuthentication
import Security

/// The device identity of shipped builds: three CryptoKit Secure Enclave
/// P-256 keys. It creates the keys with the protection the caller passes for
/// each one, exports their wrapped blobs, restores from them, and reports an
/// unusable identity when a key no longer works. It stores nothing.
///
/// Each approval signature restores the approval key with a new
/// authentication context that has an empty fallback title (no passcode
/// button) and is invalidated afterwards, so a key protected with
/// `biometryCurrentSet` asks for Face ID or Touch ID every time.
///
/// CI cannot run the Secure Enclave; this type is verified on real devices
/// (#290).
public final class SecureEnclaveDeviceIdentity: DeviceIdentity, @unchecked Sendable {
    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public let keyBlobs: DeviceIdentityKeyBlobs
    public let messagePublicKey: P256.Signing.PublicKey
    public let agreementPublicKey: P256.KeyAgreement.PublicKey
    public let approvalPublicKey: P256.Signing.PublicKey
    private let messageKey: SecureEnclave.P256.Signing.PrivateKey
    private let agreementKey: SecureEnclave.P256.KeyAgreement.PrivateKey

    private init(keyBlobs: DeviceIdentityKeyBlobs, messageKey: SecureEnclave.P256.Signing.PrivateKey,
                 agreementKey: SecureEnclave.P256.KeyAgreement.PrivateKey,
                 approvalPublicKey: P256.Signing.PublicKey) {
        self.keyBlobs = keyBlobs
        self.messageKey = messageKey
        self.agreementKey = agreementKey
        messagePublicKey = messageKey.publicKey
        agreementPublicKey = agreementKey.publicKey
        self.approvalPublicKey = approvalPublicKey
    }

    /// Creates three new keys. The caller stores `keyBlobs`.
    public static func create(protections: DeviceKeyProtections) throws -> SecureEnclaveDeviceIdentity {
        guard isAvailable else { throw DeviceIdentityError.secureEnclaveUnavailable }
        do {
            let message = try SecureEnclave.P256.Signing.PrivateKey(
                compactRepresentable: false, accessControl: accessControl(protections.message))
            let agreement = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                compactRepresentable: false, accessControl: accessControl(protections.agreement))
            let approval = try SecureEnclave.P256.Signing.PrivateKey(
                compactRepresentable: false, accessControl: accessControl(protections.approval))
            let blobs = DeviceIdentityKeyBlobs(message: message.dataRepresentation,
                                               agreement: agreement.dataRepresentation,
                                               approval: approval.dataRepresentation)
            return SecureEnclaveDeviceIdentity(keyBlobs: blobs, messageKey: message, agreementKey: agreement,
                                               approvalPublicKey: approval.publicKey)
        } catch {
            throw DeviceIdentityError.keyCreationFailed
        }
    }

    /// Restores the keys from their blobs. A blob that no longer restores,
    /// for example one copied to another Mac, makes the identity unusable.
    public static func restore(from blobs: DeviceIdentityKeyBlobs) throws -> SecureEnclaveDeviceIdentity {
        guard isAvailable else { throw DeviceIdentityError.secureEnclaveUnavailable }
        do {
            let message = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blobs.message)
            let agreement = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blobs.agreement)
            // Restoring reads only the public key; using the key needs a context.
            let approval = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blobs.approval)
            return SecureEnclaveDeviceIdentity(keyBlobs: blobs, messageKey: message, agreementKey: agreement,
                                               approvalPublicKey: approval.publicKey)
        } catch {
            throw classify(error)
        }
    }

    public func signWithMessageKey(_ data: Data) throws -> Data {
        do {
            return try messageKey.signature(for: data).rawRepresentation
        } catch {
            throw Self.classify(error)
        }
    }

    public func signWithApprovalKey(_ data: Data, reason: String) async throws -> Data {
        let blob = keyBlobs.approval
        // A biometric signature blocks its thread until the person answers.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = LAContext()
                context.localizedFallbackTitle = ""
                context.localizedReason = reason
                defer { context.invalidate() }
                do {
                    let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob,
                                                                        authenticationContext: context)
                    continuation.resume(returning: try key.signature(for: data).rawRepresentation)
                } catch {
                    continuation.resume(throwing: Self.classify(error))
                }
            }
        }
    }

    public func openHPKE(_ ciphertext: Data, encapsulatedKey: Data, info: Data,
                         preSharedKey: HPKEPreSharedKey?) throws -> Data {
        var recipient: HPKE.Recipient
        do {
            // The module checks that the encapsulated key is a valid P-256
            // point before calling, so a failure here comes from the key.
            if let preSharedKey {
                recipient = try HPKE.Recipient(privateKey: agreementKey, ciphersuite: .P256_SHA256_AES_GCM_256,
                                               info: info, encapsulatedKey: encapsulatedKey,
                                               presharedKey: preSharedKey.key,
                                               presharedKeyIdentifier: preSharedKey.identifier)
            } else {
                recipient = try HPKE.Recipient(privateKey: agreementKey, ciphersuite: .P256_SHA256_AES_GCM_256,
                                               info: info, encapsulatedKey: encapsulatedKey)
            }
        } catch {
            throw Self.classify(error)
        }
        return try recipient.open(ciphertext)
    }

    private static func accessControl(_ protection: DeviceKeyProtection) throws -> SecAccessControl {
        let accessibility: CFString
        switch protection.accessibility {
        case .afterFirstUnlockThisDeviceOnly: accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenUnlockedThisDeviceOnly: accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        if protection.authentication == .biometryCurrentSet {
            flags.insert(.biometryCurrentSet)
        }
        guard let control = SecAccessControlCreateWithFlags(nil, accessibility, flags, nil) else {
            throw DeviceIdentityError.keyCreationFailed
        }
        return control
    }

    /// Maps a Secure Enclave failure. Cancelled or failed authentication can
    /// be retried; anything else means the key no longer works.
    static func classify(_ error: Error) -> DeviceIdentityError {
        if let identityError = error as? DeviceIdentityError { return identityError }
        var pending: [NSError] = [error as NSError]
        while let nsError = pending.popLast() {
            if nsError.domain == LAErrorDomain {
                switch LAError.Code(rawValue: nsError.code) {
                case .userCancel, .appCancel, .systemCancel, .userFallback, .notInteractive:
                    return .authenticationCancelled
                case .authenticationFailed, .biometryLockout:
                    return .authenticationFailed
                case .biometryNotAvailable:
                    return .authenticationUnavailable
                default:
                    return .unusable
                }
            }
            if nsError.domain == TKError.errorDomain {
                switch TKError.Code(rawValue: nsError.code) {
                case .canceledByUser:
                    return .authenticationCancelled
                case .authenticationFailed, .authenticationNeeded:
                    return .authenticationFailed
                default:
                    break
                }
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(underlying)
            }
        }
        return .unusable
    }
}
