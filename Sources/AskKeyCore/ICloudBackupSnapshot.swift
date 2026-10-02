import Foundation
import Security

public struct ICloudBackupSnapshot: Codable, Equatable, Sendable {
    // Version 1 readers must not silently restore recycled credentials as active.
    public static let formatVersion = 2

    public let formatVersion: Int
    public let credentials: [ICloudBackupCredential]
    public let groupNames: [String]
    public let settings: ICloudBackupSettings

    var hasSupportedFormatVersion: Bool {
        (1...Self.formatVersion).contains(formatVersion)
    }

    public init(
        credentials: [ICloudBackupCredential],
        groupNames: [String],
        settings: ICloudBackupSettings
    ) {
        formatVersion = Self.formatVersion
        self.credentials = credentials
        self.groupNames = groupNames
        self.settings = settings
    }

    func requiringApprovalAfterRestore() -> ICloudBackupSnapshot {
        ICloudBackupSnapshot(
            credentials: credentials.map { $0.requiringApprovalAfterRestore() },
            groupNames: groupNames,
            settings: settings
        )
    }
}

public struct ICloudBackupCredential: Codable, Equatable, Sendable {
    public enum Payload: Codable, Equatable, Sendable {
        case text(String)
        case file(bytes: Data, originalFilename: String)
        case bundle(Data)
    }

    public let id: String
    public let displayName: String
    public let payload: Payload
    public let usageInstructions: String
    public let privateNotes: String
    public let groupName: String?
    public let environmentVariable: String?
    public let permission: CredentialPermission
    public let expiresAt: Date?
    public let deletedAt: Date?

    public init(
        id: String,
        displayName: String,
        payload: Payload,
        usageInstructions: String = "",
        privateNotes: String = "",
        groupName: String? = nil,
        environmentVariable: String? = nil,
        permission: CredentialPermission,
        expiresAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.payload = payload
        self.usageInstructions = usageInstructions
        self.privateNotes = privateNotes
        self.groupName = groupName
        self.environmentVariable = environmentVariable
        self.permission = permission
        self.expiresAt = expiresAt
        self.deletedAt = deletedAt
    }

    fileprivate func requiringApprovalAfterRestore() -> ICloudBackupCredential {
        ICloudBackupCredential(
            id: id,
            displayName: displayName,
            payload: payload,
            usageInstructions: usageInstructions,
            privateNotes: privateNotes,
            groupName: groupName,
            environmentVariable: environmentVariable,
            permission: .ask,
            expiresAt: expiresAt,
            deletedAt: deletedAt
        )
    }
}

/// Deliberately contains only portable ordinary settings. Access records,
/// requests, timed allowances, temporary files, pause state, client state and
/// biometric preferences have no representation in the backup schema.
public struct ICloudBackupSettings: Codable, Equatable, Sendable {
    public let languageMode: String
    public let appearanceMode: String
    public let defaultTimedAllowanceMinutes: Int
    public let launchAtLogin: Bool

    public init(
        languageMode: String,
        appearanceMode: String,
        defaultTimedAllowanceMinutes: Int,
        launchAtLogin: Bool
    ) {
        self.languageMode = languageMode
        self.appearanceMode = appearanceMode
        self.defaultTimedAllowanceMinutes = defaultTimedAllowanceMinutes
        self.launchAtLogin = launchAtLogin
    }
}

public protocol ICloudBackupRestoreTarget {
    func restoreLibraryAtomically(
        with snapshot: ICloudBackupSnapshot,
        persistLocalSafetySnapshot: (Data) throws -> Void
    ) throws
}

public struct ICloudBackupKeyMaterial: Codable, Equatable, Sendable {
    public let recoveryKey: BackupRecoveryKey
    public let writerID: String

    public init(recoveryKey: BackupRecoveryKey, writerID: String) throws {
        guard let writer = UUID(uuidString: writerID) else {
            throw ICloudBackupError.invalidGeneration("writer ID")
        }
        self.recoveryKey = recoveryKey
        self.writerID = writer.uuidString.lowercased()
    }

    public static func generate() throws -> ICloudBackupKeyMaterial {
        try ICloudBackupKeyMaterial(
            recoveryKey: BackupRecoveryKey.generate(),
            writerID: UUID().uuidString
        )
    }
}

public protocol ICloudBackupMaterialStore {
    func save(_ material: ICloudBackupKeyMaterial) throws
    func load(keyID: String) throws -> ICloudBackupKeyMaterial?
    func delete(keyID: String) throws
}

public protocol ICloudBackupLocalStateStore: AnyObject {
    func beginExclusiveAccess(namespace: String)
    func endExclusiveAccess(namespace: String)
    func isAutomaticBackupPaused(namespace: String) throws -> Bool
    func setAutomaticBackupPaused(_ paused: Bool, namespace: String) throws
    func acceptedTakeoverGeneration(namespace: String) throws -> String?
    func setAcceptedTakeoverGeneration(_ generationID: String?, namespace: String) throws
    func pendingCleanupPaths(namespace: String) throws -> [String]
    func setPendingCleanupPaths(_ paths: [String], namespace: String) throws
    /// Saving must be durable before it returns: a cloud claim can follow.
    func pendingUpload(namespace: String) throws -> Data?
    func setPendingUpload(_ data: Data?, namespace: String) throws
    func stopAllAutomaticBackups()
    func resumeAutomaticBackupsForNewInstallation()
}

public final class UserDefaultsICloudBackupLocalStateStore: ICloudBackupLocalStateStore {
    // ponytail: one process-wide lock is intentionally conservative; split by
    // namespace only if measured backup contention ever matters.
    private static let accessLock = NSLock()
    private let defaults: UserDefaults
    private let allBackupsStoppedKey: String
    private let pendingUploads: FileICloudBackupPendingUploadStore

    public convenience init() {
        self.init(
            defaults: .standard,
            pendingUploadDirectory: VaultConfiguration.applicationSupportDirectory
                .appendingPathComponent("backup-pending-uploads", isDirectory: true)
        )
    }

    /// Custom defaults require an explicit journal directory, so tests cannot
    /// silently persist upload material in the real application's data.
    public init(
        defaults: UserDefaults,
        pendingUploadDirectory: URL,
        allBackupsStoppedKey: String = VaultConfiguration.isDevelopmentBuild
            ? "icloudBackupAllStopped.dev"
            : "icloudBackupAllStopped"
    ) {
        self.defaults = defaults
        self.allBackupsStoppedKey = allBackupsStoppedKey
        pendingUploads = FileICloudBackupPendingUploadStore(directory: pendingUploadDirectory)
    }

    public func beginExclusiveAccess(namespace: String) { Self.accessLock.lock() }
    public func endExclusiveAccess(namespace: String) { Self.accessLock.unlock() }

    public func isAutomaticBackupPaused(namespace: String) throws -> Bool {
        defaults.bool(forKey: allBackupsStoppedKey) || defaults.bool(forKey: key(namespace))
    }

    public func setAutomaticBackupPaused(_ paused: Bool, namespace: String) throws {
        defaults.set(paused, forKey: key(namespace))
    }

    public func acceptedTakeoverGeneration(namespace: String) throws -> String? {
        defaults.string(forKey: takeoverKey(namespace))
    }

    public func setAcceptedTakeoverGeneration(_ generationID: String?, namespace: String) throws {
        defaults.set(generationID, forKey: takeoverKey(namespace))
    }

    public func pendingCleanupPaths(namespace: String) throws -> [String] {
        defaults.stringArray(forKey: cleanupKey(namespace)) ?? []
    }

    public func setPendingCleanupPaths(_ paths: [String], namespace: String) throws {
        defaults.set(paths, forKey: cleanupKey(namespace))
    }

    public func pendingUpload(namespace: String) throws -> Data? {
        try pendingUploads.read(namespace: namespace)
    }

    public func setPendingUpload(_ data: Data?, namespace: String) throws {
        try pendingUploads.write(data, namespace: namespace)
    }

    public func stopAllAutomaticBackups() {
        Self.accessLock.lock()
        defaults.set(true, forKey: allBackupsStoppedKey)
        Self.accessLock.unlock()
    }

    public func resumeAutomaticBackupsForNewInstallation() {
        Self.accessLock.lock()
        defaults.removeObject(forKey: allBackupsStoppedKey)
        Self.accessLock.unlock()
    }

    private func key(_ namespace: String) -> String {
        "icloudBackupPaused.\(namespace)"
    }

    private func takeoverKey(_ namespace: String) -> String {
        "icloudBackupTakeover.\(namespace)"
    }

    private func cleanupKey(_ namespace: String) -> String {
        "icloudBackupCleanup.\(namespace)"
    }
}

public final class SystemICloudBackupMaterialStore: ICloudBackupMaterialStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func save(_ material: ICloudBackupKeyMaterial) throws {
        guard KeychainQuery.systemKeychainAllowed else {
            throw ICloudBackupError.keyMaterialWriteFailed(errSecInteractionNotAllowed)
        }
        let data = try JSONEncoder().encode(material)
        let query = KeychainQuery.forbidAuthenticationUI([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: material.recoveryKey.keyID,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ])
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ICloudBackupError.keyMaterialWriteFailed(status)
        }
    }

    public func load(keyID: String) throws -> ICloudBackupKeyMaterial? {
        guard KeychainQuery.systemKeychainAllowed else {
            throw ICloudBackupError.keyMaterialReadFailed(errSecInteractionNotAllowed)
        }
        let query = KeychainQuery.forbidAuthenticationUI([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        var value: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw ICloudBackupError.keyMaterialReadFailed(status)
        }
        do {
            return try JSONDecoder().decode(ICloudBackupKeyMaterial.self, from: data)
        } catch {
            throw ICloudBackupError.invalidRecoveryKey
        }
    }

    public func delete(keyID: String) throws {
        guard KeychainQuery.systemKeychainAllowed else {
            throw ICloudBackupError.keyMaterialWriteFailed(errSecInteractionNotAllowed)
        }
        let query = KeychainQuery.forbidAuthenticationUI([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyID,
        ])
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ICloudBackupError.keyMaterialWriteFailed(status)
        }
    }

    public func deleteAll() throws {
        guard KeychainQuery.systemKeychainAllowed else {
            throw ICloudBackupError.keyMaterialWriteFailed(errSecInteractionNotAllowed)
        }
        let query = KeychainQuery.forbidAuthenticationUI([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ])
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ICloudBackupError.keyMaterialWriteFailed(status)
        }
    }
}

public final class ICloudBackupNamespaceManager {
    private let cloud: ICloudBackupStore
    private let materials: ICloudBackupMaterialStore
    private let state: ICloudBackupLocalStateStore

    public init(
        cloud: ICloudBackupStore,
        materials: ICloudBackupMaterialStore,
        state: ICloudBackupLocalStateStore
    ) {
        self.cloud = cloud
        self.materials = materials
        self.state = state
    }

    /// Enabling after disable always produces a new recovery key namespace;
    /// existing namespaces and their recovery keys remain independently usable.
    public func createNewBackupNamespace() throws -> ICloudBackupKeyMaterial {
        let material = try ICloudBackupKeyMaterial.generate()
        try materials.save(material)
        state.resumeAutomaticBackupsForNewInstallation()
        return material
    }

    public func stopAutomaticBackups(namespace: String) throws {
        state.beginExclusiveAccess(namespace: namespace)
        defer { state.endExclusiveAccess(namespace: namespace) }
        try state.setAutomaticBackupPaused(true, namespace: namespace)
    }

    public func cloudNamespaces() throws -> [String] {
        let paths = try cloud.list(prefix: "askkey-backup")
        return Array(Set(paths.compactMap { path in
            let components = path.split(separator: "/")
            guard components.count >= 2, components[0] == "askkey-backup" else { return nil }
            return String(components[1])
        })).sorted()
    }

    /// Cloud deletion is deliberately separate from stopping backups and
    /// requires an explicit human-authenticated call.
    public func deleteCloudNamespace(
        _ namespace: String,
        using authenticator: ManagementAuthenticator
    ) throws {
        guard namespace.count == 32,
              namespace.allSatisfy({ $0.isHexDigit }),
              authenticator.confirm(reason: "Delete Ask Key iCloud backup") else {
            throw ICloudBackupError.authenticationRequired
        }
        state.beginExclusiveAccess(namespace: namespace)
        defer { state.endExclusiveAccess(namespace: namespace) }
        try state.setAutomaticBackupPaused(true, namespace: namespace)
        for path in try cloud.list(prefix: "askkey-backup/\(namespace)") {
            try cloud.delete(at: path)
        }
        try materials.delete(keyID: namespace)
        try state.setAcceptedTakeoverGeneration(nil, namespace: namespace)
        try state.setPendingCleanupPaths([], namespace: namespace)
        try state.setPendingUpload(nil, namespace: namespace)
    }
}
