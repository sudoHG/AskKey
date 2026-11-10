import AskKeyDevices
import AskKeyVault
import CloudKit
import CryptoKit
import Foundation
import os

/// What differs between the real device services and the ones the E2E App
/// and tests use: key creation, the inbox transport, the iCloud account and
/// the clock. The coordinator's logic is the same for all of them. The
/// production App creates `CloudKitDeviceServicesBackend` only behind
/// `CloudKitGate`; `AppRuntimeConfiguration.makeDeviceServices` replaces it.
package protocol DeviceServicesBackend: AnyObject, Sendable {
    var clock: any DeviceClock { get }
    var isSecureEnclaveAvailable: Bool { get }
    /// Whether the App registers for remote notifications, which carry the
    /// push hints of this backend's transport.
    var registersForRemoteNotifications: Bool { get }
    /// New keys with the Mac's protections; nothing is stored yet.
    func createIdentity() throws -> (identity: any DeviceIdentity, blobs: DeviceIdentityKeyBlobs)
    /// Throws `DeviceIdentityError.unusable` when a blob no longer restores.
    func restoreIdentity(from blobs: DeviceIdentityKeyBlobs) throws -> any DeviceIdentity
    func makeInbox(for device: DeviceID) -> any DeviceInbox
    /// Yields whenever the iCloud account may have changed.
    func accountChanges() -> AsyncStream<Void>
    /// Whether a remote notification is a hint for `device`'s own inbox. A
    /// hint only means "fetch now"; nothing in it is trusted or shown.
    func isPushHint(_ userInfo: [AnyHashable: Any], for device: DeviceID) -> Bool
}

/// One device's inbox: the message transport plus the account and inbox
/// calls `CloudKitDeviceTransport` makes.
package protocol DeviceInbox: DeviceTransport {
    func prepareInbox() async throws -> InboxPreparation
    func accountState(storedUserRecordName: String?) async -> CloudKitAccountState
    func removeInbox() async throws
}

extension CloudKitDeviceTransport: DeviceInbox {}

/// The real backend: Secure Enclave keys and the CloudKit transport on the
/// container the gate allowed.
package final class CloudKitDeviceServicesBackend: DeviceServicesBackend {
    /// ADR 0013 → Key access control, for the Mac: every key is usable after
    /// the first unlock, on this device only, with no per-use authentication.
    /// Each human step is gated in the App by the management session and
    /// system authentication.
    package static let macKeyProtections = DeviceKeyProtections(
        message: DeviceKeyProtection(accessibility: .afterFirstUnlockThisDeviceOnly, authentication: .none),
        agreement: DeviceKeyProtection(accessibility: .afterFirstUnlockThisDeviceOnly, authentication: .none),
        approval: DeviceKeyProtection(accessibility: .afterFirstUnlockThisDeviceOnly, authentication: .none)
    )

    private let containerIdentifier: String
    package let clock: any DeviceClock = SystemDeviceClock()

    package init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
    }

    package var isSecureEnclaveAvailable: Bool { SecureEnclaveDeviceIdentity.isAvailable }
    package var registersForRemoteNotifications: Bool { true }

    package func createIdentity() throws -> (identity: any DeviceIdentity, blobs: DeviceIdentityKeyBlobs) {
        let identity = try SecureEnclaveDeviceIdentity.create(protections: Self.macKeyProtections)
        return (identity, identity.keyBlobs)
    }

    package func restoreIdentity(from blobs: DeviceIdentityKeyBlobs) throws -> any DeviceIdentity {
        try SecureEnclaveDeviceIdentity.restore(from: blobs)
    }

    package func makeInbox(for device: DeviceID) -> any DeviceInbox {
        CloudKitDeviceTransport(containerIdentifier: containerIdentifier, deviceID: device, platform: .macOS)
    }

    package func accountChanges() -> AsyncStream<Void> {
        CloudKitDeviceTransport.accountChanges()
    }

    package func isPushHint(_ userInfo: [AnyHashable: Any], for device: DeviceID) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return false }
        return CloudKitInboxLayout.isPush(notification, for: device)
    }
}

/// Where the coordinator keeps the inbox token and the account it belongs to.
package protocol DeviceInboxStateStore: AnyObject {
    func load() throws -> DeviceInboxState
    func save(_ state: DeviceInboxState) throws
}

/// The production store: a file in the library directory, through the Vault.
package final class VaultDeviceInboxStateStore: DeviceInboxStateStore {
    private let vault: Vault

    package init(vault: Vault) {
        self.vault = vault
    }

    package func load() throws -> DeviceInboxState { try vault.loadDeviceInboxState() }
    package func save(_ state: DeviceInboxState) throws { try vault.saveDeviceInboxState(state) }
}

/// The Mac's identity as its messenger sees it. The Mac's approval key has
/// no per-use authentication (ADR 0013), so every approval signature first
/// asks for system authentication through `authorize`, which also records
/// it with the Vault for the pairing session. Only `confirmPairing` reaches
/// an approval signature, and only after an accepted code; a cancelled or
/// failed prompt throws and signs nothing.
final class PairingAuthorizingIdentity: DeviceIdentity, @unchecked Sendable {
    private let base: any DeviceIdentity
    private let authorize: @Sendable (String) async throws -> Void

    init(base: any DeviceIdentity, authorize: @escaping @Sendable (String) async throws -> Void) {
        self.base = base
        self.authorize = authorize
    }

    var messagePublicKey: P256.Signing.PublicKey { base.messagePublicKey }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { base.agreementPublicKey }
    var approvalPublicKey: P256.Signing.PublicKey { base.approvalPublicKey }
    var deviceID: DeviceID { DeviceID(messagePublicKey: base.messagePublicKey) }

    func signWithMessageKey(_ data: Data) throws -> Data {
        try base.signWithMessageKey(data)
    }

    func signWithApprovalKey(_ data: Data, reason: String) async throws -> Data {
        try await authorize(reason)
        return try await base.signWithApprovalKey(data, reason: reason)
    }

    func openHPKE(_ ciphertext: Data, encapsulatedKey: Data, info: Data,
                  preSharedKey: HPKEPreSharedKey?) throws -> Data {
        try base.openHPKE(ciphertext, encapsulatedKey: encapsulatedKey, info: info, preSharedKey: preSharedKey)
    }
}

/// What the device services log. No event carries message content, codes,
/// names, keys, device IDs or account identifiers.
package enum DeviceServicesEvent: Hashable, Sendable {
    /// The responder's reveal was verified; the Mac now asks for the code.
    case revealVerified
    case pairingEnded(PairingEndReason)
    case devicePaired
    case messageRefused(DeviceMessageRefusal)
    case identityUnusable
    case accountChanged
    case inboxPreparationFailed
    case pollFailed

    package static let systemLog: @Sendable (DeviceServicesEvent) -> Void = { event in
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AskKeyAppKit", category: "Devices")
        logger.notice("\(String(describing: event), privacy: .public)")
    }
}
