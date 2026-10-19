import Foundation
import LocalAuthentication
import Security

/// Production operations always open this file, independently of user Keychain
/// preferences. Native CI validation may inject temporary files, never login.
struct PinnedAppKeychain {
    private let url: URL
    private let additionalSearchURLs: [URL]
    private let isolated: Bool

    static var login: Self { .init(url: loginURL, additionalSearchURLs: [], isolated: false) }
    private static var loginURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db")
    }

    init(temporaryKeychainURL: URL, additionalSearchURLs: [URL] = []) throws {
        url = temporaryKeychainURL
        self.additionalSearchURLs = additionalSearchURLs
        isolated = true
        try validateAccessAllowed()
    }

    private init(url: URL, additionalSearchURLs: [URL], isolated: Bool) {
        self.url = url
        self.additionalSearchURLs = additionalSearchURLs
        self.isolated = isolated
    }

    func validateAccessAllowed() throws {
        if isolated {
            let environment = ProcessInfo.processInfo.environment
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
            guard environment["CI"] == "true", environment["GITHUB_ACTIONS"] == "true",
                  NSClassFromString("XCTestCase") != nil,
                  ([url] + additionalSearchURLs).allSatisfy({
                      $0.isFileURL && $0.resolvingSymlinksInPath().path.hasPrefix(root)
                          && $0.lastPathComponent.hasSuffix(".keychain-db")
                  }) else { throw AppKeyStoreError.securityFailure(errSecInteractionNotAllowed) }
        } else {
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
        for candidate in [pinned] + (try additionalSearchURLs.map(Self.open)) {
            let path = try Self.path(candidate)
            if try !searched.contains(where: { try Self.path($0) == path }) { searched.append(candidate) }
        }
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
