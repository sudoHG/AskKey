import CryptoKit
import Foundation
import Security
import XCTest
@testable import AskKeyVault

/// The only native, mutating Keychain fixture. The guard precedes even preference
/// reads; local tests cannot open login, the default keychain, or the search list.
final class KeychainNativeTestSupport {
    let root: URL
    let pinnedURL: URL
    let outsideURL: URL
    let service = "com.sudohg.askkey.tests.native.\(UUID().uuidString)"
    let application: URL
    private let before: KeychainPreferencesSnapshot
    private var pinned: SecKeychain?
    private var outside: SecKeychain?
    private let password = "synthetic-\(UUID().uuidString)"

    init(test: XCTestCase) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CI"] == "true", environment["GITHUB_ACTIONS"] == "true" else {
            throw XCTSkip("Native Keychain integration runs only in CI.")
        }
        before = try KeychainPreferencesSnapshot()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyNative-\(UUID().uuidString)")
        pinnedURL = root.appendingPathComponent("pinned.keychain-db")
        outsideURL = root.appendingPathComponent("outside.keychain-db")
        application = try XCTUnwrap(Bundle.main.executableURL)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        do {
            pinned = try create(pinnedURL)
            outside = try create(outsideURL)
        } catch {
            try? cleanup()
            throw error
        }
        test.addTeardownBlock { try self.cleanup() }
    }

    func makeStore() throws -> AppBoundKeyStore {
        AppBoundKeyStore(legacyService: service + ".legacy", pendingService: service + ".pending",
                         appService: service, trustedApplicationURL: application,
                         keychain: try PinnedAppKeychain(temporaryKeychainURL: pinnedURL, additionalSearchURLs: [outsideURL]))
    }

    func addPolicy(_ data: Data, outside: Bool = false, permissive: Bool = false) throws -> NativeItem {
        try add(data, service: service, account: "agent-access-policy", outside: outside,
                permissive: permissive)
    }

    func addVaultKey(_ data: Data, suffix: String = "", outside: Bool = false) throws {
        _ = try add(data, service: service + suffix, account: "vault-key", outside: outside)
    }

    func policyData(outside: Bool = false) throws -> Data? {
        var query = query(service: service, account: "agent-access-policy", outside: outside)
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return try XCTUnwrap(result as? Data)
    }

    func assertOldItemReplaced(_ item: NativeItem, file: StaticString = #filePath, line: UInt = #line) throws {
        // File-keychain references may resolve the new item by its primary key.
        // A new item loses this unrelated attribute; a data/ACL update keeps it.
        var query = query(service: service, account: "agent-access-policy", outside: false)
        query[kSecReturnAttributes as String] = true
        var result: AnyObject?
        try check(SecItemCopyMatching(query as CFDictionary, &result))
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertNotEqual(attributes[kSecAttrGeneric as String] as? Data, item.marker, file: file, line: line)
        XCTAssertTrue((attributes[kSecAttrGeneric as String] as? Data ?? Data()).isEmpty, file: file, line: line)
    }

    func makePinnedFileImmutable() throws {
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: pinnedURL.path)
    }

    func pinnedFileBytes() throws -> Data { try Data(contentsOf: pinnedURL) }

    func assertNativePolicyDeleteFails() throws {
        let status = SecItemDelete(query(service: service, account: "agent-access-policy", outside: false) as CFDictionary)
        XCTAssertNotEqual(status, errSecSuccess, "Fixture must cause a native delete failure")
    }

    func assertAppOnlyPolicy(file: StaticString = #filePath, line: UInt = #line) throws {
        var query = query(service: service, account: "agent-access-policy", outside: false)
        query[kSecReturnRef as String] = true
        var result: AnyObject?
        try check(SecItemCopyMatching(query as CFDictionary, &result))
        let item = try XCTUnwrap(result)
        var access: SecAccess?
        try check(SecKeychainItemCopyAccess(unsafeDowncast(item, to: SecKeychainItem.self), &access))
        var entries: CFArray?
        try check(SecAccessCopyACLList(XCTUnwrap(access), &entries))
        let acl = try XCTUnwrap((entries as? [SecACL])?.first {
            (SecACLCopyAuthorizations($0) as? [String])?.contains(kSecACLAuthorizationDecrypt as String) == true
        })
        var applications: CFArray?
        var description: CFString?
        var selector = SecKeychainPromptSelector()
        try check(SecACLCopyContents(acl, &applications, &description, &selector))
        let trusted = try XCTUnwrap(applications as? [SecTrustedApplication])
        XCTAssertEqual(trusted.count, 1, file: file, line: line)
        var path: CFData?
        try check(SecTrustedApplicationCopyData(XCTUnwrap(trusted.first), &path))
        XCTAssertEqual(try XCTUnwrap(path) as Data, Data((application.path + "\0").utf8), file: file, line: line)
    }

    private func add(_ data: Data, service: String, account: String, outside: Bool,
                     permissive: Bool = false) throws -> NativeItem {
        let access = try AppKeychainAccess.make(application: application)
        if permissive {
            var entries: CFArray?
            try check(SecAccessCopyACLList(access, &entries))
            for acl in try XCTUnwrap(entries as? [SecACL]) {
                let rights = (SecACLCopyAuthorizations(acl) as? [String]) ?? []
                if rights.contains(kSecACLAuthorizationDecrypt as String) {
                    try check(SecACLSetContents(acl, nil, "Synthetic permissive item" as CFString, []))
                }
            }
        }
        let marker = Data(UUID().uuidString.utf8)
        var query = query(service: service, account: account, outside: outside)
        query.removeValue(forKey: kSecMatchSearchList as String)
        query[kSecUseKeychain as String] = try XCTUnwrap(outside ? self.outside : pinned)
        query[kSecAttrAccess as String] = access
        query[kSecValueData as String] = data
        query[kSecAttrGeneric as String] = marker
        query[kSecReturnRef as String] = true
        var result: AnyObject?
        try check(SecItemAdd(query as CFDictionary, &result))
        _ = try XCTUnwrap(result)
        return NativeItem(marker: marker)
    }

    private func query(service: String, account: String, outside: Bool) -> [String: Any] {
        KeychainQuery.forbidAuthenticationUI([
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchSearchList as String: [outside ? self.outside! : pinned!],
        ])
    }

    private func create(_ url: URL) throws -> SecKeychain {
        var result: SecKeychain?
        let status = url.path.withCString { path in
            password.withCString { bytes in
                SecKeychainCreate(path, UInt32(password.utf8.count), bytes, false, nil, &result)
            }
        }
        try check(status)
        return try XCTUnwrap(result)
    }

    private func cleanup() throws {
        defer {
            do {
                XCTAssertEqual(try KeychainPreferencesSnapshot(), before,
                               "Native tests must leave user Keychain preferences and login file unchanged")
            } catch { XCTFail("Could not verify Keychain preferences after cleanup: \(error)") }
        }
        try clearTemporaryImmutableFlags()
        for keychain in [outside, pinned].compactMap({ $0 }) { try check(SecKeychainDelete(keychain)) }
        outside = nil
        pinned = nil
        // Clear only fixture-owned backing or backup files left by the injected
        // failure, including any files produced during native deletion.
        try clearTemporaryImmutableFlags()
        try FileManager.default.removeItem(at: root)
    }

    private func clearTemporaryImmutableFlags() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: root.path)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
        ))
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw AppKeyStoreError.securityFailure(status) }
    }

    struct NativeItem { fileprivate let marker: Data }
}

private struct KeychainPreferencesSnapshot: Equatable {
    let defaultPath: String?
    let userDefaultPath: String?
    let searchPaths: [String]
    let loginContentsDigest: Data?

    init() throws {
        var keychain: SecKeychain?
        let status = SecKeychainCopyDefault(&keychain)
        guard [errSecSuccess, errSecNoDefaultKeychain].contains(status) else { throw AppKeyStoreError.securityFailure(status) }
        defaultPath = try keychain.map(PinnedAppKeychain.path)
        keychain = nil
        let userStatus = SecKeychainCopyDomainDefault(.user, &keychain)
        guard [errSecSuccess, errSecNoDefaultKeychain].contains(userStatus) else { throw AppKeyStoreError.securityFailure(userStatus) }
        userDefaultPath = try keychain.map(PinnedAppKeychain.path)
        var list: CFArray?
        let listStatus = SecKeychainCopySearchList(&list)
        guard listStatus == errSecSuccess else { throw AppKeyStoreError.securityFailure(listStatus) }
        searchPaths = try XCTUnwrap(list as? [SecKeychain]).map(PinnedAppKeychain.path)
        let login = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db")
        loginContentsDigest = try FileManager.default.fileExists(atPath: login.path) ? Data(SHA256.hash(data: Data(contentsOf: login))) : nil
    }
}
