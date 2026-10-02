import Foundation
import LocalAuthentication
import Security

enum AppKeyStoreError: Error, Equatable {
    case missingPendingKey
    case missingAppKey
    case securityFailure(OSStatus)
    case conflictingKey
}

final class AppBoundKeyStore: AppKeyStore {
    private static let account = "vault-key"

    private let legacyService: String
    private let pendingService: String
    private let appService: String
    private let trustedApplicationURL: URL

    init(
        legacyService: String,
        pendingService: String,
        appService: String,
        trustedApplicationURL: URL
    ) {
        self.legacyService = legacyService
        self.pendingService = pendingService
        self.appService = appService
        self.trustedApplicationURL = trustedApplicationURL
    }

    func savePendingKey(_ data: Data) throws {
        try saveAppBound(data, service: pendingService)
    }

    func loadPendingKey() throws -> Data {
        try load(service: pendingService, missing: .missingPendingKey)
    }

    func promotePendingKey() throws {
        try saveAppBound(try loadPendingKey(), service: appService)
    }

    func loadAppKey() throws -> Data {
        try load(service: appService, missing: .missingAppKey)
    }

    func deleteLegacyKey() throws { try delete(service: legacyService) }
    func deletePendingKey() throws { try delete(service: pendingService) }
    func deleteAppKey() throws { try delete(service: appService) }

    private func saveAppBound(_ data: Data, service: String) throws {
        guard KeychainQuery.systemKeychainAllowed else {
            throw AppKeyStoreError.securityFailure(errSecInteractionNotAllowed)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: data,
            kSecAttrAccess as String: try appOnlyAccess(),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard try load(service: service, missing: .conflictingKey) == data else {
                throw AppKeyStoreError.conflictingKey
            }
            return
        }
        guard status == errSecSuccess else {
            throw AppKeyStoreError.securityFailure(status)
        }
    }

    private func load(
        service: String,
        missing: AppKeyStoreError
    ) throws -> Data {
        guard KeychainQuery.systemKeychainAllowed else {
            throw AppKeyStoreError.securityFailure(errSecInteractionNotAllowed)
        }
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query = KeychainQuery.forbidAuthenticationUI([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext,
        ])
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw missing }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppKeyStoreError.securityFailure(status)
        }
        return data
    }

    private func delete(service: String) throws {
        guard KeychainQuery.systemKeychainAllowed else {
            throw AppKeyStoreError.securityFailure(errSecInteractionNotAllowed)
        }
        let query = KeychainQuery.forbidAuthenticationUI([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ])
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppKeyStoreError.securityFailure(status)
        }
    }

    private func appOnlyAccess() throws -> SecAccess {
        // SecTrustedApplicationCreateFromPath / SecAccessCreate are deprecated,
        // but they remain the file-based login keychain boundary that binds the
        // App-owned vault key to this app. Removing them would weaken key isolation.
        // Revisit when Apple ships a replacement that works for file keychains.
        var trustedApplication: SecTrustedApplication?
        let trustedStatus = trustedApplicationURL.path.withCString { path in
            SecTrustedApplicationCreateFromPath(path, &trustedApplication)
        }
        guard trustedStatus == errSecSuccess, let trustedApplication else {
            throw AppKeyStoreError.securityFailure(trustedStatus)
        }
        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            "Ask Key App-only vault key" as CFString,
            [trustedApplication] as CFArray,
            &access
        )
        guard accessStatus == errSecSuccess, let access else {
            throw AppKeyStoreError.securityFailure(accessStatus)
        }
        return access
    }

}

protocol AppKeyStore: AnyObject {
    func savePendingKey(_ data: Data) throws
    func loadPendingKey() throws -> Data
    func promotePendingKey() throws
    func loadAppKey() throws -> Data
    func deleteLegacyKey() throws
    func deletePendingKey() throws
    func deleteAppKey() throws
}
