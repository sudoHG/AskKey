import AskKeyDevices
import CryptoKit
import Foundation

/// A device identity with software P-256 keys, for tests only. It can
/// simulate a cancelled or failed approval prompt and a key that no longer
/// works. Shipped builds never use software keys.
public final class SoftwareDeviceIdentity: DeviceIdentity, @unchecked Sendable {
    public enum ApprovalBehavior: Sendable {
        case sign
        case cancel
        case fail
    }

    private let messageKey: P256.Signing.PrivateKey
    private let agreementKey: P256.KeyAgreement.PrivateKey
    private let approvalKey: P256.Signing.PrivateKey
    private let lock = NSLock()
    private var unusable = false
    private var behavior = ApprovalBehavior.sign
    private var reasons: [String] = []
    private var promptHook: (@Sendable () async -> Void)?

    public init() {
        messageKey = P256.Signing.PrivateKey()
        agreementKey = P256.KeyAgreement.PrivateKey()
        approvalKey = P256.Signing.PrivateKey()
    }

    /// Fixed keys, for test vectors.
    public init(messageKey: P256.Signing.PrivateKey, agreementKey: P256.KeyAgreement.PrivateKey,
                approvalKey: P256.Signing.PrivateKey) {
        self.messageKey = messageKey
        self.agreementKey = agreementKey
        self.approvalKey = approvalKey
    }

    public var messagePublicKey: P256.Signing.PublicKey { messageKey.publicKey }
    public var agreementPublicKey: P256.KeyAgreement.PublicKey { agreementKey.publicKey }
    public var approvalPublicKey: P256.Signing.PublicKey { approvalKey.publicKey }
    public var deviceID: DeviceID { DeviceID(messagePublicKey: messagePublicKey) }

    /// Makes every key operation fail as `DeviceIdentityError.unusable`.
    public var isUnusable: Bool {
        get { lock.withLock { unusable } }
        set { lock.withLock { unusable = newValue } }
    }

    /// What the next approval prompts do.
    public var approvalBehavior: ApprovalBehavior {
        get { lock.withLock { behavior } }
        set { lock.withLock { behavior = newValue } }
    }

    /// Runs while the approval prompt is up, before the signature is made,
    /// for example to let time pass or to hold the prompt open by suspending.
    public var duringApprovalPrompt: (@Sendable () async -> Void)? {
        get { lock.withLock { promptHook } }
        set { lock.withLock { promptHook = newValue } }
    }

    /// The prompt reason of every approval signature requested so far.
    public var approvalReasons: [String] { lock.withLock { reasons } }

    public func signWithMessageKey(_ data: Data) throws -> Data {
        guard !isUnusable else { throw DeviceIdentityError.unusable }
        return try messageKey.signature(for: data).rawRepresentation
    }

    public func signWithApprovalKey(_ data: Data, reason: String) async throws -> Data {
        let (behavior, hook): (ApprovalBehavior, (@Sendable () async -> Void)?) = lock.withLock {
            reasons.append(reason)
            return (unusable ? .fail : self.behavior, promptHook)
        }
        await hook?()
        guard !isUnusable else { throw DeviceIdentityError.unusable }
        switch behavior {
        case .sign: return try approvalKey.signature(for: data).rawRepresentation
        case .cancel: throw DeviceIdentityError.authenticationCancelled
        case .fail: throw DeviceIdentityError.authenticationFailed
        }
    }

    public func openHPKE(_ ciphertext: Data, encapsulatedKey: Data, info: Data,
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
