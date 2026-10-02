import CryptoKit
import Foundation
import GRDB
import Security
import AskKeyBroker

public final class Vault {
#if DEBUG && ASKKEY_E2E_TESTING
    public static let shared = VaultE2EFixture.makeVault()
#else
    public static let shared = Vault()
#endif
    private static let defaultFileDeliveryManager = FileDeliveryManagerRegistry()
    public let brokerRequests = BrokerRequestRegistry()
    public let approvalRequests: BrokerApprovalStateMachine
    let agentTextWrites = FrozenAgentTextWriteRegistry()

    // The daemon serves on background threads while the app uses Vault.shared on
    // the main thread (ADR 0014), so the shared key/store are lock-guarded. The
    // lock is never held across a Keychain or DB call (GRDB serializes the DB
    // itself) and never re-entered, so it can't deadlock.
    public static let managementSessionIdleLimit: TimeInterval = 5 * 60

    private let stateLock = NSLock()
    private let lifecycleLock = NSRecursiveLock()
    let agentAccessGate = AgentAccessGate()
    let fileDeliveryManager: FileDeliveryManagerRegistry
    private let clock: () -> Date
    private var _key: SymmetricKey?
    private var _store: VaultStore?
    private var _managementSessionExpiresAt: Date?
    private var _accessRecordWriteFailed = false

    func notifySnapshotRelevantChange() {
        NotificationCenter.default.post(name: .askKeyCredentialSnapshotDidChange, object: nil)
    }

    private var key: SymmetricKey? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _key }
        set {
            stateLock.lock()
            _key = newValue
            _store?.bindCredentialAuthenticationKey(newValue)
            stateLock.unlock()
        }
    }

    var store: VaultStore {
        get throws {
            stateLock.lock()
            defer { stateLock.unlock() }
            if let _store { return _store }
            // Store creation belongs exclusively to the verified bootstrap.
            // Metadata queries before unlock must never create/upgrade vault.db.
            throw VaultError.vaultLocked
        }
    }

    private init() {
        approvalRequests = BrokerApprovalStateMachine()
        fileDeliveryManager = Self.defaultFileDeliveryManager
        clock = Date.init
        configureAgentTextWriteCleanup()
    }

    /// Test seam: build a Vault over an explicit store (and optional key) so
    /// credential logic can be exercised without the real vault file or
    /// Keychain. Not used in production code.
    init(
        store: VaultStore,
        key: SymmetricKey? = nil,
        now: @escaping () -> Date = Date.init,
        approvalRequests: BrokerApprovalStateMachine = BrokerApprovalStateMachine(),
        fileDeliveryManager: FileDeliveryManager? = nil
    ) {
        self._store = store
        self.clock = now
        self.approvalRequests = approvalRequests
        if let fileDeliveryManager {
            self.fileDeliveryManager = FileDeliveryManagerRegistry(manager: fileDeliveryManager)
        } else {
            let testRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("AskKeyTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            self.fileDeliveryManager = FileDeliveryManagerRegistry(
                retryDelay: 1,
                factory: { try FileDeliveryManager(rootURL: testRoot) }
            )
        }
        self.key = key
        do {
            try synchronizeAgentAccessState()
        } catch {
            agentAccessGate.invalidate()
        }
        configureAgentTextWriteCleanup()
    }

    public func updateDefaultTimedAllowanceMinutes(_ minutes: Int) {
        let seconds: TimeInterval
        if minutes > 0, minutes <= Int.max / 60 {
            seconds = TimeInterval(minutes * 60)
        } else {
            seconds = 30 * 60
        }
        approvalRequests.updateDefaultTimedAllowance(seconds)
        notifySnapshotRelevantChange()
    }

    public func validateStoreAvailability() throws {
        _ = try bootstrapState()
    }

    public func bootstrapState() throws -> VaultBootstrapState {
        try VaultConfiguration.validateRuntimeIsolation()
        return try VaultBootstrap.state(paths: bootstrapPaths)
    }

    func credentialCountForBootstrap() throws -> Int {
        stateLock.lock()
        let current = _store
        stateLock.unlock()
        if let current {
            return try current.db.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM credentials") ?? 0
            }
        }
        try VaultConfiguration.validateRuntimeIsolation()
        return try VaultBootstrap.credentialCount(paths: bootstrapPaths)
    }

    private func configureAgentTextWriteCleanup() {
        approvalRequests.configureOperationStateChanged { [weak self] operationID, request, state in
            guard let self else { return }
            if state != .pending, state != .approved {
                let frozen = self.agentTextWrites.entry(operationID: operationID)
                self.agentTextWrites.remove(operationID: operationID)
                if let approvalRequest = request ?? frozen?.approvalRequest,
                   state == .denied || state == .cancelled || state == .expired {
                    let operation: CredentialAccessEvent.Operation
                    switch approvalRequest.operation {
                    case .create: operation = .create
                    case .modify: operation = .modify
                    case .delete: operation = .delete
                    case .read: operation = .runtimeRead
                    }
                    self.recordCredentialAccess(.init(
                        timestamp: self.currentDate,
                        credentialID: approvalRequest.credentialID,
                        operation: operation,
                        result: .denied,
                        callerHint: approvalRequest.callerName,
                        declaredPurpose: approvalRequest.callerPurpose
                    ))
                }
            }
        }
    }

    // MARK: - Setup

    /// Loads only the App-owned current format for background Agent work.
    /// Human management remains independently locked.
    public func prepareAgentRuntime() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        try VaultConfiguration.validateRuntimeIsolation()
        try prepareAgentRuntime(paths: bootstrapPaths, keyStore: { try self.appKeyStore() })
    }

    // Explicit synthetic paths/key store keep startup tests off the real vault.
    func prepareAgentRuntime(paths: VaultBootstrapPaths, keyStore: () throws -> AppKeyStore) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stateLock.lock()
        let alreadyLoaded = _store != nil && _key != nil
        stateLock.unlock()
        if alreadyLoaded { return }

        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: try keyStore())
        try adoptBootstrappedLibrary(opened)
    }

    public func unlock() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        try VaultConfiguration.validateRuntimeIsolation()
        try recoverInterruptedLocalErase()
        try openBootstrappedLibrary()
    }

    public func lock() {
        approvalRequests.revokeAllTimedAllowances()
        key = nil
        endManagementSession()
    }

    public var isLocked: Bool { key == nil }

    public var hasActiveManagementSession: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isManagementSessionValidLocked()
    }

    public func beginManagementSession(using authenticator: ManagementAuthenticator) throws {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        _ = try requireKey()
        stateLock.lock()
        _managementSessionExpiresAt = clock().addingTimeInterval(Self.managementSessionIdleLimit)
        stateLock.unlock()
    }

    public func beginOnboardingManagementSession() throws {
        try beginOnboardingCreation()
    }

    /// Validates the first-creation path without granting list/reveal/settings
    /// access. Creation checks emptiness again under the mutation gate.
    public func beginOnboardingCreation() throws {
        _ = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        guard try store.fetchAllCredentials().isEmpty,
              try store.fetchRecycledCredentials().isEmpty else {
            throw VaultError.managementAuthenticationRequired
        }
    }

    func performCredentialCreation<T>(
        using authenticator: ManagementAuthenticator,
        _ create: () throws -> T
    ) throws -> T {
        _ = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        let isFirst = try store.fetchAllCredentials().isEmpty && store.fetchRecycledCredentials().isEmpty
        if !isFirst {
            try requireManagementSession()
            try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        }
        let created = try create()
        notifySnapshotRelevantChange()
        return created
    }

    public func endManagementSession() {
        stateLock.lock()
        _managementSessionExpiresAt = nil
        stateLock.unlock()
    }

    func requireManagementSession() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isManagementSessionValidLocked() else {
            _managementSessionExpiresAt = nil
            throw VaultError.managementAuthenticationRequired
        }
        _managementSessionExpiresAt = clock().addingTimeInterval(Self.managementSessionIdleLimit)
    }

    private func isManagementSessionValidLocked() -> Bool {
        guard let expires = _managementSessionExpiresAt else { return false }
        return clock() < expires
    }

    var currentDate: Date { clock() }

    func setAccessRecordWriteFailed(_ failed: Bool) {
        stateLock.lock()
        _accessRecordWriteFailed = failed
        stateLock.unlock()
    }

    var accessRecordWriteFailed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _accessRecordWriteFailed
    }

    func authorizeManagement(_ authenticator: ManagementAuthenticator, reason: String) throws {
        guard authenticator.confirm(reason: reason) else {
            throw VaultError.managementAuthenticationRequired
        }
    }

    // MARK: - Environment variable names

    /// Credential environment-variable mappings must use POSIX shell identifiers,
    /// so a mapped name is always a valid, unambiguous key in the environment a
    /// credential is delivered into. `CredentialFieldValidation` applies this rule
    /// to every credential and component mapping before it is stored.
    static let secretNamePattern = "^[A-Za-z_][A-Za-z0-9_]*$"

    static func validateSecretName(_ name: String) throws {
        guard name.utf8.count <= BrokerLimits.maximumFieldBytes else {
            throw VaultError.invalidSecretName(name)
        }
        let range = NSRange(name.startIndex..., in: name)
        guard let regex = try? NSRegularExpression(pattern: secretNamePattern),
              regex.firstMatch(in: name, range: range) != nil else {
            throw VaultError.invalidSecretName(name)
        }
    }

    // MARK: - Helpers

    func requireKey() throws -> SymmetricKey {
        guard let key else {
            throw VaultError.vaultLocked
        }
        return key
    }

    private var bootstrapPaths: VaultBootstrapPaths {
        .init(directory: VaultConfiguration.applicationSupportDirectory)
    }

    private func openBootstrappedLibrary() throws {
        let opened = try VaultBootstrap.openCurrent(paths: bootstrapPaths, keyStore: appKeyStore())
        try adoptBootstrappedLibrary(opened)
    }

    private func adoptBootstrappedLibrary(_ opened: (store: VaultStore, key: SymmetricKey)) throws {
        stateLock.lock()
        let oldStore = _store
        _key = opened.key
        _store = opened.store
        stateLock.unlock()
        if let oldStore, oldStore !== opened.store { try oldStore.close() }
        do {
            try synchronizeAgentAccessState()
        } catch {
            lock()
            throw error
        }
    }

    func appKeyStore() throws -> AppKeyStore {
        try makeAppKeyStore(
            legacyService: VaultConfiguration.keychainService,
            pendingService: VaultConfiguration.pendingAppKeychainService,
            appService: VaultConfiguration.appKeychainService
        )
    }

    func deleteAllLocalVaultKeys() throws {
        for store in [try appKeyStore(), try makeAppKeyStore(
            legacyService: VaultConfiguration.keychainService,
            pendingService: VaultConfiguration.previousAppKeychainService + ".migration",
            appService: VaultConfiguration.previousAppKeychainService
        )] {
            try store.deleteLegacyKey()
            try store.deletePendingKey()
            try store.deleteAppKey()
        }
    }

    private func makeAppKeyStore(
        legacyService: String, pendingService: String, appService: String
    ) throws -> AppKeyStore {
        try VaultConfiguration.validateRuntimeIsolation()
        #if DEBUG
        if let directory = VaultConfiguration.debugRunDirectory {
            return try IsolatedAppKeyStore(
                directory: directory, legacyService: legacyService,
                pendingService: pendingService, appService: appService
            )
        }
        #endif
        guard let executableURL = Bundle.main.executableURL else {
            throw AppKeyStoreError.securityFailure(errSecParam)
        }
        return AppBoundKeyStore(
            legacyService: legacyService,
            pendingService: pendingService,
            appService: appService,
            trustedApplicationURL: executableURL
        )
    }

    func closeStoreForLocalErase() throws {
        stateLock.lock()
        let current = _store
        stateLock.unlock()
        try current?.close()
        stateLock.lock()
        if _store === current { _store = nil }
        stateLock.unlock()
    }

    func finishLocalErase() {
        stateLock.lock()
        _key = nil
        _store?.bindCredentialAuthenticationKey(nil)
        _store = nil
        _managementSessionExpiresAt = nil
        stateLock.unlock()
    }
}
