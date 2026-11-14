import AskKeyDevices
import CryptoKit
import Darwin
import Foundation

/// Why the Mac's device storage refused an operation (ADR 0013).
public enum DeviceStorageError: Error, Equatable, Sendable {
    /// Some but not all of the three key items exist. The identity is
    /// unusable; resetting it deletes the keys and the list.
    case incompleteIdentity
    /// A key item failed authentication: this library did not store it, for
    /// example because another App planted it. The identity is refused, not
    /// used; resetting it deletes the keys and the list.
    case identityRefused
    /// A device identity is already stored. It is never replaced, only reset.
    case identityExists
    /// The stored paired-device list failed authentication or does not
    /// decode. It is refused, not repaired; resetting the identity deletes it.
    case listRefused
    /// A list change would add a device the person did not authorize, with
    /// system authentication, in the current pairing session.
    case pairingNotAuthorized
    /// A list change would turn on a device's approval flag without the
    /// approver authorization for that device and pairing (ADR 0014).
    case approverNotAuthorized
    /// A local erase is running or was interrupted; device storage stays
    /// closed until it finishes.
    case eraseInProgress
    /// The device services this storage was opened for were stopped by a
    /// local erase or an identity reset; nothing they started can write.
    case servicesStopped
}

/// The device services' inbox position (ADR 0013 → Push is a hint), kept in
/// the library directory, so it belongs to this storage namespace and goes
/// with a local erase. Losing it only causes a full fetch.
public struct DeviceInboxState: Codable, Equatable, Sendable {
    /// The iCloud account the paired-device list belongs to: the account
    /// signed in when the identity was created, or one adopted while the list
    /// was empty. Another signed-in account is an account change.
    public var listAccount: String?
    /// The inbox change token after the last fully processed poll.
    public var inboxToken: Data?
    /// The account `inboxToken` belongs to; a token of another account is dropped.
    public var tokenAccount: String?

    public init(listAccount: String? = nil, inboxToken: Data? = nil, tokenAccount: String? = nil) {
        self.listAccount = listAccount
        self.inboxToken = inboxToken
        self.tokenAccount = tokenAccount
    }
}

/// What the Vault keeps in memory for the device services: the storage
/// epoch, the epoch's only list registry, the pairing and approver
/// authorizations, and the handler that stops the services before a local erase.
final class VaultDeviceState: @unchecked Sendable {
    struct Approver: Equatable {
        let deviceID: DeviceID
        let pairingID: PairingID
    }

    private let lock = NSRecursiveLock()
    private var epoch = 0
    private var registry: PairedDeviceRegistry?
    private var authorizedPeer: DeviceID?
    private var authorizedApprover: Approver?
    private var stopHandler: (@Sendable () -> Void)?

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var currentEpoch: Int { withLock { epoch } }

    func setStopHandler(_ handler: (@Sendable () -> Void)?) { withLock { stopHandler = handler } }

    func registry(_ make: (Int) -> PairedDeviceRegistry) -> PairedDeviceRegistry {
        withLock {
            if let registry { return registry }
            let made = make(epoch)
            registry = made
            return made
        }
    }

    func authorize(_ peer: DeviceID?) { withLock { authorizedPeer = peer } }

    func isAuthorized(_ peer: DeviceID) -> Bool { withLock { authorizedPeer == peer } }

    func authorizeApprover(_ approver: Approver?) { withLock { authorizedApprover = approver } }

    func isApproverAuthorized(_ approver: Approver) -> Bool { withLock { authorizedApprover == approver } }

    /// Drops both authorizations, when the management session has ended.
    func dropAuthorizations() {
        withLock {
            authorizedPeer = nil
            authorizedApprover = nil
        }
    }

    /// Closes the current epoch: its store refuses every later operation and
    /// the authorization is dropped. Returns the stop handler to call.
    @discardableResult
    func endEpoch() -> (@Sendable () -> Void)? {
        withLock {
            epoch += 1
            registry = nil
            authorizedPeer = nil
            authorizedApprover = nil
            return stopHandler
        }
    }

    func finishLocalErase() { endEpoch() }
}

/// The keychain-backed list store of one storage epoch. Every load and save
/// goes through the Vault, which authenticates the item with a key derived
/// from the vault key and refuses an add the person did not authorize.
final class VaultPairedDeviceListStore: PairedDeviceListStore, @unchecked Sendable {
    private weak var vault: Vault?
    private let epoch: Int

    init(vault: Vault, epoch: Int) {
        self.vault = vault
        self.epoch = epoch
    }

    func loadPairedDeviceList() throws -> PairedDeviceList {
        guard let vault else { throw DeviceStorageError.servicesStopped }
        return try vault.loadPairedDevices(epoch: epoch)
    }

    func savePairedDeviceList(_ list: PairedDeviceList) throws {
        guard let vault else { throw DeviceStorageError.servicesStopped }
        try vault.savePairedDevices(list, epoch: epoch)
    }
}

/// The paired-device list item: the list's versioned serialization followed
/// by an HMAC-SHA256 tag over `AskKey paired devices v1` (with its NUL) and
/// those exact bytes, under a key derived from the vault key with
/// HKDF-SHA256, an empty salt and the info `AskKey paired devices key v1`
/// (with its NUL). The tag is checked before the bytes are decoded, and the
/// bytes are never re-encoded for the check (ADR 0013 → Paired-device list).
enum PairedDeviceListAuthentication {
    static let tagLength = 32
    static let tagLabel = Data("AskKey paired devices v1\0".utf8)
    static let keyInfo = Data("AskKey paired devices key v1\0".utf8)

    static func seal(_ list: PairedDeviceList, using vaultKey: SymmetricKey) throws -> Data {
        let bytes = try list.serialized()
        return bytes + Data(HMAC<SHA256>.authenticationCode(for: tagLabel + bytes, using: key(vaultKey)))
    }

    static func open(_ item: Data, using vaultKey: SymmetricKey) throws -> PairedDeviceList {
        guard item.count > tagLength else { throw DeviceStorageError.listRefused }
        let bytes = Data(item.prefix(item.count - tagLength))
        let tag = Data(item.suffix(tagLength))
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: tagLabel + bytes, using: key(vaultKey)) else {
            throw DeviceStorageError.listRefused
        }
        do {
            return try PairedDeviceList(serialized: bytes)
        } catch {
            throw DeviceStorageError.listRefused
        }
    }

    private static func key(_ vaultKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: vaultKey, salt: Data(), info: keyInfo, outputByteCount: 32)
    }
}

/// A key item: the Secure Enclave blob followed by an HMAC-SHA256 tag over
/// `AskKey device key blob v1` (with its NUL), the account name (with a NUL)
/// and the blob, under a key derived from the vault key with HKDF-SHA256,
/// an empty salt and the info `AskKey device key blob key v1` (with its NUL).
/// Any process on this Mac can use a blob it holds, so an identity whose
/// items this library did not write, such as blobs another App planted
/// before the first pairing while keeping copies, is refused.
enum DeviceKeyBlobAuthentication {
    static let tagLength = 32
    static let tagLabel = Data("AskKey device key blob v1\0".utf8)
    static let keyInfo = Data("AskKey device key blob key v1\0".utf8)

    static func seal(_ blob: Data, account: DeviceKeychainAccount, using vaultKey: SymmetricKey) -> Data {
        blob + Data(HMAC<SHA256>.authenticationCode(for: authenticated(blob, account), using: key(vaultKey)))
    }

    static func open(_ item: Data, account: DeviceKeychainAccount, using vaultKey: SymmetricKey) throws -> Data {
        guard item.count > tagLength else { throw DeviceStorageError.identityRefused }
        let blob = Data(item.prefix(item.count - tagLength))
        guard HMAC<SHA256>.isValidAuthenticationCode(Data(item.suffix(tagLength)),
                                                     authenticating: authenticated(blob, account),
                                                     using: key(vaultKey)) else {
            throw DeviceStorageError.identityRefused
        }
        return blob
    }

    private static func authenticated(_ blob: Data, _ account: DeviceKeychainAccount) -> Data {
        tagLabel + Data(account.rawValue.utf8) + Data([0]) + blob
    }

    private static func key(_ vaultKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: vaultKey, salt: Data(), info: keyInfo, outputByteCount: 32)
    }
}

extension Vault {
    /// The reason shown with the system authentication that adds a device.
    /// The App's authentication prompt accepts only the reasons of its action
    /// catalog, so pairing uses the management reason until the Devices
    /// section adds its own reason and translation (#288).
    public static let devicePairingReason = CredentialManagementCopy.manageReason

    private static let deviceKeyAccounts: [DeviceKeychainAccount] = [.messageKey, .agreementKey, .approvalKey]

    // MARK: Lifecycle

    /// The App's device services install the handler that stops them; a
    /// local erase calls it before it deletes anything.
    public func setDeviceServicesStopHandler(_ handler: (@Sendable () -> Void)?) {
        deviceState.setStopHandler(handler)
    }

    /// The first step of a local erase: no store of the current epoch writes
    /// again, the pairing authorization is dropped, and the App stops its
    /// sessions, polling, delivery checks and pending callbacks.
    func stopDeviceServicesForLocalErase() {
        // No approver keeps authority once the erase begins (ADR 0014).
        approvalRequests.removeAllActiveApprovers()
        deviceState.endEpoch()?()
    }

    /// Deletes the list first, then the three keys, so an interruption never
    /// leaves a list behind for a new identity.
    func deleteDeviceItems(from keys: AppKeyStore) throws {
        try keys.deleteDeviceItem(.pairedDevices)
        for account in Self.deviceKeyAccounts { try keys.deleteDeviceItem(account) }
    }

    // MARK: Identity

    /// The stored key blobs, or nil when this Mac has no identity. Needs no
    /// management session: messages are verified in the background. Each
    /// item's tag is checked before its blob is returned.
    public func storedDeviceIdentityKeyBlobs() throws -> DeviceIdentityKeyBlobs? {
        try withDeviceStorage { keys in
            let items = try Self.deviceKeyAccounts.map { try keys.loadDeviceItem($0) }
            if items.allSatisfy({ $0 == nil }) { return nil }
            guard let message = items[0], let agreement = items[1], let approval = items[2] else {
                throw DeviceStorageError.incompleteIdentity
            }
            let vaultKey = try requireKey()
            return DeviceIdentityKeyBlobs(
                message: try DeviceKeyBlobAuthentication.open(message, account: .messageKey, using: vaultKey),
                agreement: try DeviceKeyBlobAuthentication.open(agreement, account: .agreementKey, using: vaultKey),
                approval: try DeviceKeyBlobAuthentication.open(approval, account: .approvalKey, using: vaultKey))
        }
    }

    /// Stores a new identity's key blobs, on the first pairing. Requires the
    /// management session and refuses to replace a stored identity. A list
    /// or inbox state left without an identity is deleted first.
    public func saveDeviceIdentityKeyBlobs(_ blobs: DeviceIdentityKeyBlobs) throws {
        try requireManagementSession()
        try withDeviceStorage { keys in
            for account in Self.deviceKeyAccounts where try keys.loadDeviceItem(account) != nil {
                throw DeviceStorageError.identityExists
            }
            let vaultKey = try requireKey()
            try keys.deleteDeviceItem(.pairedDevices)
            try removeDeviceInboxStateFile()
            do {
                for (blob, account) in [(blobs.message, DeviceKeychainAccount.messageKey), (blobs.agreement, .agreementKey),
                                        (blobs.approval, .approvalKey)] {
                    try keys.saveDeviceItem(DeviceKeyBlobAuthentication.seal(blob, account: account, using: vaultKey),
                                            account: account)
                }
            } catch {
                for account in Self.deviceKeyAccounts { try? keys.deleteDeviceItem(account) }
                throw error
            }
        }
    }

    /// Resets an unusable identity: closes the storage epoch, then deletes
    /// the list, the three keys and the inbox state. Requires the management
    /// session. The caller stops its device services first.
    public func resetDeviceIdentity() throws {
        try requireManagementSession()
        approvalRequests.removeAllActiveApprovers()
        deviceState.endEpoch()
        try withDeviceStorage { keys in
            try deleteDeviceItems(from: keys)
            try removeDeviceInboxStateFile()
        }
    }

    // MARK: Paired-device list

    /// The current epoch's only registry, which commits every list change as
    /// one serialized read, modify and write. Reading needs no management
    /// session; adding a device needs `authorizeDevicePairing`.
    public func pairedDeviceRegistry() throws -> PairedDeviceRegistry {
        try withDeviceStorage { _ in
            deviceState.registry { PairedDeviceRegistry(store: VaultPairedDeviceListStore(vault: self, epoch: $0)) }
        }
    }

    /// Records the system authentication for the current pairing session,
    /// which lets one list change add `peer`. Requires the management
    /// session; an authenticator that does not confirm stores nothing.
    public func authorizeDevicePairing(with peer: DeviceID, using authenticator: ManagementAuthenticator) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: Self.devicePairingReason)
        deviceState.authorize(peer)
    }

    /// The pairing session ended, was cancelled, or management closed.
    public func endDevicePairingAuthorization() {
        deviceState.authorize(nil)
    }

    /// Records step 1's system authentication for turning on approval for one
    /// paired device (ADR 0014 → Approvers). The App writes the flag only
    /// after a verified confirmation whose code proof matches; that one list
    /// write uses the authorization up. Requires the management session; an
    /// authenticator that does not confirm stores nothing.
    package func authorizeDeviceApprover(_ deviceID: DeviceID, pairingID: PairingID,
                                         using authenticator: ManagementAuthenticator) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: Self.devicePairingReason)
        deviceState.authorizeApprover(.init(deviceID: deviceID, pairingID: pairingID))
    }

    /// The approver sheet closed, its code expired or was refused, or management locked.
    package func endDeviceApproverAuthorization() {
        deviceState.authorizeApprover(nil)
    }

    /// Renaming and removing a device need the management session; an open
    /// pairing sheet also uses this to keep it from expiring for idleness.
    public func requireDeviceManagementSession() throws {
        try requireDeviceManagementSessionDroppingAuthorization()
    }

    /// A management session that has ended also ends any pairing or approver authorization.
    private func requireDeviceManagementSessionDroppingAuthorization() throws {
        do {
            try requireManagementSession()
        } catch {
            deviceState.dropAuthorizations()
            throw error
        }
    }

    func loadPairedDevices(epoch: Int) throws -> PairedDeviceList {
        try withDeviceStorage(epoch: epoch) { keys in
            try storedPairedDevices(keys: keys, vaultKey: requireKey())
        }
    }

    /// Writes a list the registry prepared. A device that was not on the
    /// stored list, or is there with another pairing ID, is an add: it needs
    /// the management session and this pairing session's authorization for
    /// that device, which the write then uses up. Turning a device's approval
    /// flag on widens authority the same way: it needs the management session
    /// and the approver authorization for that device and pairing ID, which
    /// the write uses up. Turning it off needs the management session. A
    /// device whose flag the write turns off, or whose flagged entry it
    /// removes or replaces, leaves the Broker's active-approver set before
    /// the write commits, so its authority ends first (ADR 0014 → Revocation).
    func savePairedDevices(_ list: PairedDeviceList, epoch: Int) throws {
        try withDeviceStorage(epoch: epoch) { keys in
            let vaultKey = try requireKey()
            let stored = try storedPairedDevices(keys: keys, vaultKey: vaultKey)
            func storedEntry(_ device: PairedDevice) -> PairedDevice? {
                stored.devices.first { $0.deviceID == device.deviceID && $0.pairingID == device.pairingID }
            }
            let added = list.devices.filter { storedEntry($0) == nil }
            let enabled = list.devices.filter { $0.isApprover && storedEntry($0)?.isApprover != true }
            let disabled = list.devices.contains { !$0.isApprover && storedEntry($0)?.isApprover == true }
            if !added.isEmpty || !enabled.isEmpty || disabled {
                try requireDeviceManagementSessionDroppingAuthorization()
            }
            if !added.isEmpty {
                guard added.count == 1, deviceState.isAuthorized(added[0].deviceID) else {
                    throw DeviceStorageError.pairingNotAuthorized
                }
            }
            if !enabled.isEmpty {
                guard enabled.count == 1,
                      deviceState.isApproverAuthorized(.init(deviceID: enabled[0].deviceID,
                                                             pairingID: enabled[0].pairingID)) else {
                    throw DeviceStorageError.approverNotAuthorized
                }
            }
            for device in stored.devices where device.isApprover && !list.devices.contains(where: {
                $0.deviceID == device.deviceID && $0.pairingID == device.pairingID && $0.isApprover
            }) {
                approvalRequests.removeActiveApprover(pairingID: device.pairingID.rawValue)
            }
            try keys.saveDeviceItem(PairedDeviceListAuthentication.seal(list, using: vaultKey), account: .pairedDevices)
            if !added.isEmpty { deviceState.authorize(nil) }
            if !enabled.isEmpty { deviceState.authorizeApprover(nil) }
        }
    }

    /// The stored list, read under the device lock. Needs no management session.
    func storedPairedDeviceList() throws -> PairedDeviceList {
        try withDeviceStorage { keys in try storedPairedDevices(keys: keys, vaultKey: requireKey()) }
    }

    private func storedPairedDevices(keys: AppKeyStore, vaultKey: SymmetricKey) throws -> PairedDeviceList {
        guard let item = try keys.loadDeviceItem(.pairedDevices) else { return PairedDeviceList() }
        return try PairedDeviceListAuthentication.open(item, using: vaultKey)
    }

    // MARK: Inbox state

    public func loadDeviceInboxState() throws -> DeviceInboxState {
        try withDeviceStorage { _ in
            let url = deviceInboxStateURL
            guard FileManager.default.fileExists(atPath: url.path) else { return DeviceInboxState() }
            // A damaged file only causes a full fetch and a new account check.
            return (try? JSONDecoder().decode(DeviceInboxState.self, from: Data(contentsOf: url))) ?? DeviceInboxState()
        }
    }

    public func saveDeviceInboxState(_ state: DeviceInboxState) throws {
        try withDeviceStorage { _ in
            let data = try JSONEncoder().encode(state)
            let target = deviceInboxStateURL
            let temporary = libraryDirectory.appendingPathComponent(".device-inbox-\(UUID().uuidString).creating")
            guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard temporary.path.withCString({ source in target.path.withCString { Darwin.rename(source, $0) } }) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private var deviceInboxStateURL: URL { libraryDirectory.appendingPathComponent("device-inbox.json") }

    private func removeDeviceInboxStateFile() throws {
        let url = deviceInboxStateURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Storage

    /// Runs one device storage operation under the device lock, after
    /// checking that no local erase is pending and, for a list store, that
    /// its epoch is still the current one. Uses only the device items; the
    /// vault key comes from memory, never from its keychain item.
    private func withDeviceStorage<T>(epoch: Int? = nil, _ body: (AppKeyStore) throws -> T) throws -> T {
        try deviceState.withLock {
            if let epoch, epoch != deviceState.currentEpoch { throw DeviceStorageError.servicesStopped }
            guard !FileManager.default.fileExists(atPath: localEraseJournalURL.path) else {
                throw DeviceStorageError.eraseInProgress
            }
            return try body(policyKeyStore())
        }
    }
}
