import AskKeyDevices
import CryptoKit
import Foundation
@testable import AskKeyiOSKit

/// A device identity with software P-256 keys, for tests only. It can
/// simulate a cancelled or failed Face ID prompt and keys that no longer work.
final class SoftwareIdentity: DeviceIdentity, @unchecked Sendable {
    enum ApprovalBehavior {
        case sign
        case cancel
        case fail
    }

    private let messageKey = P256.Signing.PrivateKey()
    private let agreementKey = P256.KeyAgreement.PrivateKey()
    private let approvalKey = P256.Signing.PrivateKey()
    private let lock = NSLock()
    private var unusable = false
    private var behavior = ApprovalBehavior.sign
    private var reasons: [String] = []

    var messagePublicKey: P256.Signing.PublicKey { messageKey.publicKey }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { agreementKey.publicKey }
    var approvalPublicKey: P256.Signing.PublicKey { approvalKey.publicKey }
    var deviceID: DeviceID { DeviceID(messagePublicKey: messagePublicKey) }

    var isUnusable: Bool {
        get { lock.withLock { unusable } }
        set { lock.withLock { unusable = newValue } }
    }

    var approvalBehavior: ApprovalBehavior {
        get { lock.withLock { behavior } }
        set { lock.withLock { behavior = newValue } }
    }

    /// The prompt reason of every approval signature asked for.
    var approvalReasons: [String] { lock.withLock { reasons } }

    func signWithMessageKey(_ data: Data) throws -> Data {
        guard !isUnusable else { throw DeviceIdentityError.unusable }
        return try messageKey.signature(for: data).rawRepresentation
    }

    func signWithApprovalKey(_ data: Data, reason: String) async throws -> Data {
        let behavior: ApprovalBehavior = lock.withLock {
            reasons.append(reason)
            return self.behavior
        }
        guard !isUnusable else { throw DeviceIdentityError.unusable }
        switch behavior {
        case .sign: return try approvalKey.signature(for: data).rawRepresentation
        case .cancel: throw DeviceIdentityError.authenticationCancelled
        case .fail: throw DeviceIdentityError.authenticationFailed
        }
    }

    func openHPKE(_ ciphertext: Data, encapsulatedKey: Data, info: Data,
                  preSharedKey: HPKEPreSharedKey?) throws -> Data {
        guard !isUnusable else { throw DeviceIdentityError.unusable }
        var recipient: HPKE.Recipient
        if let preSharedKey {
            recipient = try HPKE.Recipient(privateKey: agreementKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: info,
                                           encapsulatedKey: encapsulatedKey, presharedKey: preSharedKey.key,
                                           presharedKeyIdentifier: preSharedKey.identifier)
        } else {
            recipient = try HPKE.Recipient(privateKey: agreementKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: info,
                                           encapsulatedKey: encapsulatedKey)
        }
        return try recipient.open(ciphertext)
    }
}

/// Creates software identities and restores them from their fake blobs.
final class FakeIdentityFactory: DeviceIdentityFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [Data: SoftwareIdentity] = [:]
    private var available = true
    private var creationError: DeviceIdentityError?
    private var restoreError: DeviceIdentityError?
    private(set) var createdCount = 0

    var isSecureEnclaveAvailable: Bool {
        get { lock.withLock { available } }
        set { lock.withLock { available = newValue } }
    }

    var createError: DeviceIdentityError? {
        get { lock.withLock { creationError } }
        set { lock.withLock { creationError = newValue } }
    }

    var restoringError: DeviceIdentityError? {
        get { lock.withLock { restoreError } }
        set { lock.withLock { restoreError = newValue } }
    }

    /// The identity created last.
    private(set) var latest: SoftwareIdentity?

    func create() throws -> (identity: any DeviceIdentity, blobs: DeviceIdentityKeyBlobs) {
        try lock.withLock {
            if let creationError { throw creationError }
            let identity = SoftwareIdentity()
            let blobs = DeviceIdentityKeyBlobs(message: Data(UUID().uuidString.utf8), agreement: Data(UUID().uuidString.utf8),
                                               approval: Data(UUID().uuidString.utf8))
            identities[blobs.message] = identity
            createdCount += 1
            latest = identity
            return (identity, blobs)
        }
    }

    func restore(_ blobs: DeviceIdentityKeyBlobs) throws -> any DeviceIdentity {
        try lock.withLock {
            if let restoreError { throw restoreError }
            guard let identity = identities[blobs.message] else { throw DeviceIdentityError.unusable }
            return identity
        }
    }
}
