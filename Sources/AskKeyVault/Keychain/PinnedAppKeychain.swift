import Foundation
import LocalAuthentication
import Security

/// Opens a specific file independently of user Keychain preferences.
struct PinnedAppKeychain {
    private let url: URL

    static var login: Self { .init() }
    static var loginURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db")
    }

    init(fileURL: URL = Self.loginURL) {
        url = fileURL
    }

    func validateAccessAllowed() throws {
        if url.standardizedFileURL.resolvingSymlinksInPath() == Self.loginURL.standardizedFileURL.resolvingSymlinksInPath() {
            guard KeychainQuery.systemKeychainAllowed else {
                throw AppKeyStoreError.securityFailure(errSecInteractionNotAllowed)
            }
        }
    }

    func open() throws -> Context {
        try validateAccessAllowed()
        let pinned = try Self.open(url)
        var searchList: CFArray?
        let status = SecKeychainCopySearchList(&searchList)
        guard status == errSecSuccess, let userList = searchList as? [SecKeychain] else {
            throw AppKeyStoreError.securityFailure(status)
        }
        var searched = userList
        let path = try Self.path(pinned)
        if try !searched.contains(where: { try Self.path($0) == path }) { searched.append(pinned) }
        return Context(pinned: pinned, searchList: searched)
    }

    private static func open(_ url: URL) throws -> SecKeychain {
        var keychain: SecKeychain?
        let status = url.path.withCString { SecKeychainOpen($0, &keychain) }
        guard status == errSecSuccess, let keychain else { throw AppKeyStoreError.securityFailure(status) }
        return keychain
    }

    static func path(_ keychain: SecKeychain) throws -> String {
        var bytes = [CChar](repeating: 0, count: 4097)
        var count = UInt32(bytes.count)
        let status = SecKeychainGetPath(keychain, &count, &bytes)
        guard status == errSecSuccess else { throw AppKeyStoreError.securityFailure(status) }
        return URL(fileURLWithPath: String(cString: bytes)).standardizedFileURL.resolvingSymlinksInPath().path
    }

    struct Context {
        let pinned: SecKeychain
        let searchList: [SecKeychain]

        var isUnlocked: Bool {
            var status = SecKeychainStatus()
            guard SecKeychainGetStatus(pinned, &status) == errSecSuccess else { return false }
            return status & SecKeychainStatus(kSecUnlockStateStatus) != 0
        }

        func query(service: String, account: String) -> [String: Any] {
            KeychainQuery.forbidAuthenticationUI([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecMatchSearchList as String: [pinned],
            ])
        }

        func uniqueItem(service: String, account: String) throws -> SecKeychainItem? {
            var query = query(service: service, account: account)
            query[kSecMatchSearchList as String] = searchList
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            query[kSecReturnRef as String] = true
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let items = result as? [SecKeychainItem], items.count == 1 else {
                throw status == errSecSuccess ? AppKeyStoreError.conflictingKey : .securityFailure(status)
            }
            let item = items[0]
            var owner: SecKeychain?
            let copied = SecKeychainItemCopyKeychain(item, &owner)
            guard copied == errSecSuccess, let owner else { throw AppKeyStoreError.securityFailure(copied) }
            guard try PinnedAppKeychain.path(owner) == PinnedAppKeychain.path(pinned) else {
                throw AppKeyStoreError.conflictingKey
            }
            return item
        }

        private func referenceQuery(_ item: SecKeychainItem) -> [String: Any] {
            let authentication = LAContext()
            authentication.interactionNotAllowed = true
            return KeychainQuery.forbidAuthenticationUI([
                kSecClass as String: kSecClassGenericPassword,
                kSecMatchSearchList as String: [pinned],
                kSecMatchItemList as String: [item],
                kSecUseAuthenticationContext as String: authentication,
            ])
        }

        func read(_ item: SecKeychainItem) throws -> Data {
            var query = referenceQuery(item)
            query[kSecReturnData as String] = true
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else {
                throw AppKeyStoreError.securityFailure(status)
            }
            return data
        }

        func delete(_ item: SecKeychainItem) throws {
            let status = SecItemDelete(referenceQuery(item) as CFDictionary)
            guard status == errSecSuccess else { throw AppKeyStoreError.securityFailure(status) }
        }
    }
}
