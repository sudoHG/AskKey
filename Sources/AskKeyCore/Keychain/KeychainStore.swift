import Foundation
import Security

enum KeychainQuery {
    static var systemKeychainAllowed: Bool {
        RuntimeOperationEvents.publish(.keychain)
        #if DEBUG
        if ProcessInfo.processInfo.environment["ASKKEY_DEBUG_RUN_DIRECTORY"] != nil { return false }
        #endif
        return !(ProcessInfo.processInfo.arguments.first?.contains(".xctest") ?? false)
            && NSClassFromString("XCTestCase") == nil
    }

    static func forbidAuthenticationUI(_ query: [String: Any]) -> [String: Any] {
        var query = query
        // kSecUseAuthenticationUIFail is deprecated; it is still the query
        // flag that forbids interactive keychain prompts. User presence is
        // enforced at the app layer with LocalAuthentication.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return query
    }
}

enum KeychainStore {
    private static let service = VaultConfiguration.keychainService
    private static let account = "vault-key"

    // The key lives in the file-based login keychain, which does not enforce
    // SecAccessControl flags like .userPresence (those require the
    // data-protection keychain and a signed binary with an application
    // identifier). The protection boundary is the unlocked user session;
    // user-presence checks happen at the app layer via LocalAuthentication.
    static func save(_ data: Data) throws {
        guard KeychainQuery.systemKeychainAllowed else {
            throw VaultError.keychainWriteFailed(errSecInteractionNotAllowed)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        // Plain add, never delete-then-add: this is only reached when load()
        // reported the key as absent (see Vault.unlock). A duplicate here means
        // a key actually exists but the read couldn't see it — a misconfigured
        // keychain search list, a locked keychain, or an access-control
        // mismatch after a signature change. Overwriting would replace the real
        // vault key and make the vault undecryptable, so surface the
        // contradiction instead of clobbering it.
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            throw VaultError.keychainKeyUnreachable
        default:
            throw VaultError.keychainWriteFailed(status)
        }
    }

    static func load() throws -> Data {
        guard KeychainQuery.systemKeychainAllowed else {
            throw VaultError.keychainReadFailed(errSecInteractionNotAllowed)
        }
        let query = KeychainQuery.forbidAuthenticationUI([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw VaultError.keychainReadFailed(status)
        }
        return data
    }

    static func exists() -> Bool {
        guard KeychainQuery.systemKeychainAllowed else { return false }
        let query = KeychainQuery.forbidAuthenticationUI([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ])
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        guard KeychainQuery.systemKeychainAllowed else { return }
        let query = KeychainQuery.forbidAuthenticationUI([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ])
        SecItemDelete(query as CFDictionary)
    }
}
