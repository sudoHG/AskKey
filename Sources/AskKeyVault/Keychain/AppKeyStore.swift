import Foundation
import Security

enum AppKeyStoreError: Error, Equatable {
    case missingPendingKey
    case missingAppKey
    case securityFailure(OSStatus)
    case conflictingKey
    case policyPersistenceUnknown
}

final class AppBoundKeyStore: AppKeyStore {
    private static let account = "vault-key"
    private static let policyAccount = "agent-access-policy"
    private static let operationLock = NSRecursiveLock()

    private let legacyService: String
    private let pendingService: String
    private let appService: String
    private let trustedApplicationURL: URL
    private let keychain: PinnedAppKeychain

    init(legacyService: String, pendingService: String, appService: String,
         trustedApplicationURL: URL, keychain: PinnedAppKeychain = .login) {
        self.legacyService = legacyService
        self.pendingService = pendingService
        self.appService = appService
        self.trustedApplicationURL = trustedApplicationURL
        self.keychain = keychain
    }

    func savePendingKey(_ data: Data) throws { try saveAppBound(data, service: pendingService) }
    func loadPendingKey() throws -> Data { try load(service: pendingService, missing: .missingPendingKey) }
    func promotePendingKey() throws { try saveAppBound(loadPendingKey(), service: appService) }
    func loadAppKey() throws -> Data { try load(service: appService, missing: .missingAppKey) }
    func deleteLegacyKey() throws { try delete(service: legacyService) }
    func deletePendingKey() throws { try delete(service: pendingService) }
    func deleteAppKey() throws { try delete(service: appService) }

    func loadAgentAccessPolicy() throws -> Data? {
        try withKeychain { context in
            guard let item = try context.uniqueItem(service: appService, account: Self.policyAccount) else { return nil }
            return try context.read(item)
        }
    }

    func saveAgentAccessPolicy(_ data: Data) throws {
        // The ordinary test guard still fails before any native Keychain call.
        try keychain.validateAccessAllowed()
        do {
            try withKeychain { context in
                if let item = try context.uniqueItem(service: appService, account: Self.policyAccount) {
                    // Never update an existing item's value or access. Only an
                    // item this save just created receives a valid policy.
                    try context.delete(item)
                }
                try add(data, service: appService, account: Self.policyAccount, context: context)
                try verify(data, service: appService, account: Self.policyAccount, context: context)
            }
        } catch {
            // A native failure can follow a successful write, or reveal a shadow
            // item. The caller must latch a pause until authenticated recovery.
            throw AppKeyStoreError.policyPersistenceUnknown
        }
    }

    func deleteAgentAccessPolicy() throws { try delete(service: appService, account: Self.policyAccount) }

    private func saveAppBound(_ data: Data, service: String) throws {
        try withKeychain { context in
            if try context.uniqueItem(service: service, account: Self.account) != nil {
                // Vault keys are never replaced, even when an existing item has
                // a permissive ACL or its value cannot be read without UI.
                try verify(data, service: service, account: Self.account, context: context)
                return
            }
            try add(data, service: service, account: Self.account, context: context)
            try verify(data, service: service, account: Self.account, context: context)
        }
    }

    private func add(_ data: Data, service: String, account: String, context: PinnedAppKeychain.Context) throws {
        var query = context.query(service: service, account: account)
        query.removeValue(forKey: kSecMatchSearchList as String)
        query[kSecUseKeychain as String] = context.pinned
        query[kSecValueData as String] = data
        query[kSecAttrAccess as String] = try AppKeychainAccess.make(application: trustedApplicationURL)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw AppKeyStoreError.securityFailure(status) }
    }

    private func verify(_ data: Data, service: String, account: String, context: PinnedAppKeychain.Context) throws {
        guard let item = try context.uniqueItem(service: service, account: account),
              try context.read(item) == data else { throw AppKeyStoreError.conflictingKey }
    }

    private func load(service: String, missing: AppKeyStoreError) throws -> Data {
        try withKeychain { context in
            guard let item = try context.uniqueItem(service: service, account: Self.account) else { throw missing }
            return try context.read(item)
        }
    }

    private func delete(service: String, account: String = AppBoundKeyStore.account) throws {
        try withKeychain { context in
            if let item = try context.uniqueItem(service: service, account: account) { try context.delete(item) }
        }
    }

    private func withKeychain<T>(_ operation: (PinnedAppKeychain.Context) throws -> T) throws -> T {
        try keychain.validateAccessAllowed()
        Self.operationLock.lock()
        defer { Self.operationLock.unlock() }
        return try operation(keychain.open())
    }
}

package protocol AppKeyStore: AnyObject {
    func savePendingKey(_ data: Data) throws
    func loadPendingKey() throws -> Data
    func promotePendingKey() throws
    func loadAppKey() throws -> Data
    func deleteLegacyKey() throws
    func deletePendingKey() throws
    func deleteAppKey() throws
    func loadAgentAccessPolicy() throws -> Data?
    func saveAgentAccessPolicy(_ data: Data) throws
    func deleteAgentAccessPolicy() throws
}
