import AskKeyDevices
import Foundation
import Security

/// Items in one keychain service, by account.
public protocol SecureItemStore: Sendable {
    func data(for account: String) throws -> Data?
    func setData(_ data: Data, for account: String) throws
    /// Deleting an item that does not exist succeeds.
    func deleteData(for account: String) throws
}

public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus
}

/// The iPhone's data protection keychain (ADR 0013 → Device identity and
/// Paired-device list): every item is accessible after first unlock, on
/// this device only, never synchronized, in the shared access group the
/// stage 4 notification extension will also read.
public final class DataProtectionKeychain: SecureItemStore, @unchecked Sendable {
    public static let service = "com.sudohg.askkey.ios.devices"
    private let accessGroup: String?

    /// `accessGroup` is `$(AppIdentifierPrefix)com.sudohg.askkey.ios.shared`,
    /// read from the Info.plist key `KeychainAccessGroup`.
    public init(accessGroup: String?) {
        self.accessGroup = accessGroup
    }

    public convenience init(bundle: Bundle = .main) {
        let group = (bundle.object(forInfoDictionaryKey: "KeychainAccessGroup") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        self.init(accessGroup: group)
    }

    private func query(_ account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        return query
    }

    public func data(for account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return data
    }

    public func setData(_ data: Data, for account: String) throws {
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        let added = SecItemAdd(query(account).merging(attributes) { $1 } as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    public func deleteData(for account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// The keychain accounts of the iPhone's identity and list, the same names
/// the Mac uses (ADR 0013 → Identifiers).
enum DeviceKeychainAccount {
    static let messageKey = "device-message-key"
    static let agreementKey = "device-agreement-key"
    static let approvalKey = "device-approval-key"
    static let pairedDevices = "paired-devices"
    static let all = [messageKey, agreementKey, approvalKey, pairedDevices]
}

enum StoredIdentityError: Error, Equatable {
    /// Some but not all of the three key blobs are stored.
    case incomplete
}

/// The three key blobs in the keychain.
struct IdentityKeychain {
    let store: any SecureItemStore

    /// Nil when no key is stored; throws `StoredIdentityError.incomplete`
    /// when only some are, and the keychain's error when it cannot be read.
    func loadBlobs() throws -> DeviceIdentityKeyBlobs? {
        let message = try store.data(for: DeviceKeychainAccount.messageKey)
        let agreement = try store.data(for: DeviceKeychainAccount.agreementKey)
        let approval = try store.data(for: DeviceKeychainAccount.approvalKey)
        if message == nil, agreement == nil, approval == nil { return nil }
        guard let message, let agreement, let approval else { throw StoredIdentityError.incomplete }
        return DeviceIdentityKeyBlobs(message: message, agreement: agreement, approval: approval)
    }

    func save(_ blobs: DeviceIdentityKeyBlobs) throws {
        try store.setData(blobs.message, for: DeviceKeychainAccount.messageKey)
        try store.setData(blobs.agreement, for: DeviceKeychainAccount.agreementKey)
        try store.setData(blobs.approval, for: DeviceKeychainAccount.approvalKey)
    }

    /// Deletes the keys and the paired-device list; every deletion is tried.
    func deleteEverything() throws {
        var firstError: Error?
        for account in DeviceKeychainAccount.all {
            do {
                try store.deleteData(for: account)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }
}

/// The paired-device list as one keychain item. Only the app process writes
/// it (ADR 0013 → Paired-device list); a stored list that does not decode
/// is refused, not repaired.
final class PairedDeviceListKeychainStore: PairedDeviceListStore, @unchecked Sendable {
    private let store: any SecureItemStore

    init(store: any SecureItemStore) {
        self.store = store
    }

    func loadPairedDeviceList() throws -> PairedDeviceList {
        guard let data = try store.data(for: DeviceKeychainAccount.pairedDevices) else { return PairedDeviceList() }
        return try PairedDeviceList(serialized: data)
    }

    func savePairedDeviceList(_ list: PairedDeviceList) throws {
        try store.setData(try list.serialized(), for: DeviceKeychainAccount.pairedDevices)
    }
}
