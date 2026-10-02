import Darwin
import Foundation
import AskKeyBroker

public extension Notification.Name {
    static let askKeyFileDeliveryCleanupFailed = Notification.Name(
        "com.sudohg.askkey.file-delivery-cleanup-failed"
    )
}

public struct FileDeliveryCleanupFailure: Equatable, Sendable {
    public let path: String
    public let message: String
}

public final class FileDelivery: @unchecked Sendable {
    public let url: URL
    public let expiresAt: Date
    private let lock = NSLock()
    private weak var manager: FileDeliveryManager?
    private var token: UUID?

    fileprivate init(url: URL, expiresAt: Date, token: UUID, manager: FileDeliveryManager) {
        self.url = url
        self.expiresAt = expiresAt
        self.token = token
        self.manager = manager
    }

    deinit { finish() }

    public func finish() {
        lock.lock()
        let current = token
        token = nil
        lock.unlock()
        if let current { manager?.cleanup(token: current) }
    }
}

public final class FileDeliveryManager: @unchecked Sendable {
    public static let maximumTTL: TimeInterval = 5 * 60
    typealias CleanupScheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    private struct Entry {
        let credentialID: String
        let url: URL
        let requiresOwnerLease: Bool
    }

    private let rootURL: URL
    private let ownerLease: FileDeliveryOwnerLease
    private let ttl: TimeInterval
    private let retryDelay: TimeInterval
    private let clock: @Sendable () -> Date
    private let schedule: CleanupScheduler
    private let removeItem: @Sendable (URL) throws -> Void
    private let synchronizeFile: @Sendable (Int32) -> Int32
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var failuresByPath: [String: FileDeliveryCleanupFailure] = [:]
    private var cleanupInProgress: Set<UUID> = []

    public convenience init() throws {
        let root: URL
        if let runDirectory = try DebugRunDirectory.resolve() {
            root = runDirectory.appendingPathComponent("file-deliveries", isDirectory: true)
        } else {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(VaultConfiguration.isDevelopmentBuild ? "AskKey/dev" : "AskKey", isDirectory: true)
                .appendingPathComponent("file-deliveries", isDirectory: true)
        }
        try self.init(rootURL: root)
    }

    init(
        rootURL: URL,
        ttl: TimeInterval = maximumTTL,
        retryDelay: TimeInterval = 1,
        now: @escaping @Sendable () -> Date = Date.init,
        schedule: @escaping CleanupScheduler = { delay, action in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: action)
        },
        removeItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        synchronizeFile: @escaping @Sendable (Int32) -> Int32 = { fsync($0) }
    ) throws {
        guard ttl.isFinite, ttl > 0, ttl <= Self.maximumTTL,
              retryDelay.isFinite, retryDelay > 0 else {
            throw VaultError.databaseError("File delivery lifetime is invalid.")
        }
        try Self.prepareDirectory(rootURL)
        let namespaceFD = Darwin.open(rootURL.appendingPathComponent(".namespace-lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard namespaceFD >= 0 else {
            throw VaultError.databaseError("Temporary credential namespace could not be locked.")
        }
        defer { Darwin.close(namespaceFD) }
        guard flock(namespaceFD, LOCK_EX | LOCK_NB) == 0 else {
            throw VaultError.databaseError("Temporary credential namespace could not be locked.")
        }
        let instanceURL = rootURL.appendingPathComponent("instance-\(UUID().uuidString)", isDirectory: true)
        try Self.prepareDirectory(instanceURL)
        let owner = instanceURL.appendingPathComponent(".owner-lock")
        let descriptor = Darwin.open(owner.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw VaultError.databaseError("Temporary credential owner could not be created.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw VaultError.databaseError("Temporary credential owner could not be locked.")
        }
        self.ownerLease = FileDeliveryOwnerLease(descriptor: descriptor)
        self.rootURL = instanceURL
        self.ttl = ttl
        self.retryDelay = retryDelay
        self.clock = now
        self.schedule = schedule
        self.removeItem = removeItem
        self.synchronizeFile = synchronizeFile
        try sweepCrashResidue(in: rootURL)
    }

    deinit { cleanupAll() }

    public func materialize(
        credentialID: String,
        bytes: Data,
        expiresAt: Date? = nil,
        authorization: BrokerRuntimeReadAuthorization? = nil
    ) throws -> FileDelivery {
        try authorization?.validate()
        let now = clock()
        let deliveryExpiresAt = ([now.addingTimeInterval(ttl), expiresAt, authorization?.expiresAt]
            .compactMap { $0 }).min()!
        guard deliveryExpiresAt > now else { throw VaultError.credentialUnavailable }
        let token = UUID()
        let url = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw VaultError.databaseError("Temporary credential file could not be created.")
        }
        do {
            try bytes.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw VaultError.databaseError("Temporary credential file could not be written.")
                    }
                    offset += count
                }
            }
            guard synchronizeFile(descriptor) == 0 else {
                throw VaultError.databaseError("Temporary credential file could not be synchronized.")
            }
        } catch {
            _ = Darwin.close(descriptor)
            manageFailedMaterialization(url: url, credentialID: credentialID)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else {
            manageFailedMaterialization(url: url, credentialID: credentialID)
            throw VaultError.databaseError("Temporary credential file could not be closed.")
        }

        lock.lock()
        entries[token] = Entry(credentialID: credentialID, url: url, requiresOwnerLease: false)
        lock.unlock()
        do {
            // Writing/fsync consumed part (or all) of the original lifetime.
            // Never return an already expired file or restart its full TTL.
            let remaining = deliveryExpiresAt.timeIntervalSince(clock())
            guard remaining > 0 else { throw VaultError.credentialUnavailable }
            scheduleCleanup(token: token, after: remaining)
            // Invalidation may have happened before or during materialization.
            // Registration either joins that exact authorization or immediately
            // cleans this token; a later grant has a different identity.
            try authorization?.registerCleanup { [weak self] in self?.cleanup(token: token) }
            try authorization?.validate()
            // Scope registration can wait behind a concurrent authorized spawn.
            guard clock() < deliveryExpiresAt else { throw VaultError.credentialUnavailable }
        } catch {
            cleanup(token: token)
            throw error
        }
        return FileDelivery(
            url: url,
            expiresAt: deliveryExpiresAt,
            token: token,
            manager: self
        )
    }

    public func revoke(credentialID: String) {
        lock.lock()
        let tokens = entries.compactMap { $0.value.credentialID == credentialID ? $0.key : nil }
        lock.unlock()
        tokens.forEach(cleanup)
    }

    public func cleanupAll() {
        lock.lock()
        let tokens = Array(entries.keys)
        lock.unlock()
        tokens.forEach(cleanup)
    }

    public var cleanupFailures: [FileDeliveryCleanupFailure] {
        lock.lock(); defer { lock.unlock() }
        return failuresByPath.values.sorted { $0.path < $1.path }
    }

    fileprivate func cleanup(token: UUID) {
        lock.lock()
        guard let entry = entries[token] else { lock.unlock(); return }
        guard cleanupInProgress.insert(token).inserted else { lock.unlock(); return }
        lock.unlock()
        defer {
            lock.lock()
            cleanupInProgress.remove(token)
            lock.unlock()
        }

        var ownerFD: Int32 = -1
        defer { if ownerFD >= 0 { Darwin.close(ownerFD) } }
        if entry.requiresOwnerLease {
            let ownerURL = entry.url.appendingPathComponent(".owner-lock")
            ownerFD = ownerURL.path.withCString {
                Darwin.open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            }
            guard ownerFD >= 0 else {
                let code = errno
                if code == ENOENT && Self.pathIsDefinitelyAbsent(entry.url) {
                    forget(token: token, path: entry.url.path)
                } else {
                    recordCleanupFailure(
                        token: token,
                        url: entry.url,
                        error: Self.posixError(code: code)
                    )
                }
                return
            }
            guard flock(ownerFD, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK || code == EAGAIN {
                    // The instance became live again. Never remove it without
                    // holding its owner lease, and discard this stale entry.
                    forget(token: token, path: entry.url.path)
                } else {
                    recordCleanupFailure(
                        token: token,
                        url: entry.url,
                        error: Self.posixError(code: code)
                    )
                }
                return
            }
        }

        do {
            try removeItem(entry.url)
            forget(token: token, path: entry.url.path)
        } catch {
            if Self.isNoSuchFile(error) {
                forget(token: token, path: entry.url.path)
                return
            }
            recordCleanupFailure(token: token, url: entry.url, error: error)
        }
    }

    private func manageFailedMaterialization(url: URL, credentialID: String) {
        let token = UUID()
        lock.lock()
        entries[token] = Entry(credentialID: credentialID, url: url, requiresOwnerLease: false)
        lock.unlock()
        cleanup(token: token)
    }

    private func recordCleanupFailure(token: UUID, url: URL, error: Error) {
        lock.lock()
        failuresByPath[url.path] = FileDeliveryCleanupFailure(
            path: url.path,
            message: error.localizedDescription
        )
        lock.unlock()
        Self.reportCleanupFailure()
        scheduleCleanup(token: token, after: retryDelay)
    }

    private func forget(token: UUID, path: String) {
        lock.lock()
        entries.removeValue(forKey: token)
        failuresByPath.removeValue(forKey: path)
        lock.unlock()
    }

    private func scheduleCleanup(token: UUID, after delay: TimeInterval) {
        schedule(delay) { [weak self] in
            self?.cleanup(token: token)
        }
    }

    private func sweepCrashResidue(in namespace: URL) throws {
        for url in try FileManager.default.contentsOfDirectory(
            at: namespace,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            if url == rootURL { continue }
            var leaseFD: Int32 = -1
            let requiresOwnerLease = url.lastPathComponent.hasPrefix("instance-")
            if requiresOwnerLease {
                // An advisory owner lock survives for exactly the live manager.
                // Never sweep another live instance, including one in this PID.
                leaseFD = Darwin.open(url.appendingPathComponent(".owner-lock").path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
                if leaseFD < 0 {
                    let code = errno
                    if code == ENOENT && Self.pathIsDefinitelyAbsent(url) { continue }
                    trackSweepFailure(
                        url: url,
                        requiresOwnerLease: true,
                        error: Self.posixError(code: code)
                    )
                    continue
                }
                if flock(leaseFD, LOCK_EX | LOCK_NB) != 0 {
                    let code = errno
                    Darwin.close(leaseFD)
                    leaseFD = -1
                    if code == EWOULDBLOCK || code == EAGAIN { continue }
                    trackSweepFailure(
                        url: url,
                        requiresOwnerLease: true,
                        error: Self.posixError(code: code)
                    )
                    continue
                }
            }
            defer { if leaseFD >= 0 { Darwin.close(leaseFD) } }
            do {
                try removeItem(url)
            } catch {
                if Self.isNoSuchFile(error) { continue }
                trackSweepFailure(
                    url: url,
                    requiresOwnerLease: requiresOwnerLease,
                    error: error
                )
            }
        }
    }

    private func trackSweepFailure(url: URL, requiresOwnerLease: Bool, error: Error) {
        let token = UUID()
        lock.lock()
        entries[token] = Entry(
            credentialID: "",
            url: url,
            requiresOwnerLease: requiresOwnerLease
        )
        lock.unlock()
        recordCleanupFailure(token: token, url: url, error: error)
    }

    private static func pathIsDefinitelyAbsent(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }

    private static func posixError(code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func isNoSuchFile(_ error: Error) -> Bool {
        if let error = error as? POSIXError, error.code == .ENOENT {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.Code.fileNoSuchFile.rawValue {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isNoSuchFile(underlying)
        }
        return false
    }

    static func reportCleanupFailure() {
        NotificationCenter.default.post(name: .askKeyFileDeliveryCleanupFailed, object: nil)
    }

    private static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() else {
            throw VaultError.databaseError("Temporary credential directory is not an owned ordinary directory.")
        }
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw VaultError.databaseError("Temporary credential directory permissions could not be set.")
        }
    }
}

private final class FileDeliveryOwnerLease {
    private let descriptor: Int32
    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { _ = Darwin.close(descriptor) }
}

final class FileDeliveryManagerRegistry: @unchecked Sendable {
    typealias Factory = @Sendable () throws -> FileDeliveryManager

    private let lock = NSLock()
    private let retryDelay: TimeInterval
    private let factory: Factory
    private var manager: FileDeliveryManager?
    private var initializationError: Error?
    private var retryScheduled = false

    convenience init() {
        self.init(retryDelay: 1, factory: { try FileDeliveryManager() })
    }

    init(manager: FileDeliveryManager) {
        retryDelay = 1
        factory = { manager }
        self.manager = manager
    }

    init(retryDelay: TimeInterval, factory: @escaping Factory) {
        self.retryDelay = retryDelay.isFinite && retryDelay > 0 ? retryDelay : 1
        self.factory = factory
        attemptInitialization()
    }

    func get() throws -> FileDeliveryManager {
        lock.lock(); defer { lock.unlock() }
        if let manager { return manager }
        throw initializationError
            ?? VaultError.databaseError("Temporary credential cleanup is unavailable.")
    }

    func revoke(credentialID: String) {
        do {
            try get().revoke(credentialID: credentialID)
        } catch {
            FileDeliveryManager.reportCleanupFailure()
        }
    }

    func cleanupAll() {
        do {
            try get().cleanupAll()
        } catch {
            FileDeliveryManager.reportCleanupFailure()
        }
    }

    var hasFailures: Bool {
        lock.lock()
        let currentManager = manager
        let unavailable = initializationError != nil
        lock.unlock()
        return unavailable || !(currentManager?.cleanupFailures.isEmpty ?? true)
    }

    private func attemptInitialization() {
        do {
            let created = try factory()
            lock.lock()
            manager = created
            initializationError = nil
            retryScheduled = false
            lock.unlock()
        } catch {
            lock.lock()
            manager = nil
            initializationError = error
            let shouldSchedule = !retryScheduled
            retryScheduled = true
            lock.unlock()
            FileDeliveryManager.reportCleanupFailure()
            if shouldSchedule { scheduleRetry() }
        }
    }

    private func scheduleRetry() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.retryScheduled = false
            self.lock.unlock()
            self.attemptInitialization()
        }
    }
}
