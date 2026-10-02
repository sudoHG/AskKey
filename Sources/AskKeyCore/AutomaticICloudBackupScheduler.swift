import Foundation

/// Persisted change/confirmed versions. A crash before upload intent still
/// leaves `changeVersion > confirmedVersion`, so launch compensation retries.
public struct AutomaticBackupChangeLedger: Equatable, Sendable {
    public var changeVersion: Int
    public var confirmedVersion: Int

    public init(changeVersion: Int = 0, confirmedVersion: Int = 0) {
        self.changeVersion = changeVersion
        self.confirmedVersion = confirmedVersion
    }

    public var hasUnconfirmedChange: Bool { changeVersion > confirmedVersion }

    public mutating func noteChange() {
        changeVersion += 1
    }

    public mutating func confirm(upTo version: Int) {
        if version > confirmedVersion {
            confirmedVersion = min(version, changeVersion)
        }
    }

    public mutating func confirmAll() {
        confirmedVersion = changeVersion
    }
}

/// Coalesces successful library/settings changes into one cancellable backup
/// writer. Confirmation happens only after a backup covers that change version.
public final class AutomaticICloudBackupScheduler: @unchecked Sendable {
    public static var shared: AutomaticICloudBackupScheduler?

    public struct Cancellation {
        public let cancel: () -> Void
        public init(cancel: @escaping () -> Void) {
            self.cancel = cancel
        }
    }

    public typealias Backup = () throws -> ICloudBackupGeneration
    public typealias Schedule = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Cancellation

    private let lock = NSLock()
    private var backup: Backup
    private var isEnabled: () throws -> Bool
    private var hasPendingUpload: () throws -> Bool
    private let loadLedger: () -> AutomaticBackupChangeLedger
    private let persistLedger: (AutomaticBackupChangeLedger) -> Void
    private let schedule: Schedule
    private let mergeDelay: TimeInterval
    private let retryDelay: TimeInterval
    private var pending: Cancellation?
    private var writing = false
    private var halted = false
    private var generation = 0
    public private(set) var lastGeneration: ICloudBackupGeneration?
    public private(set) var lastError: Error?

    public init(
        backup: @escaping Backup,
        isEnabled: @escaping () throws -> Bool,
        hasPendingUpload: @escaping () throws -> Bool,
        loadLedger: @escaping () -> AutomaticBackupChangeLedger,
        persistLedger: @escaping (AutomaticBackupChangeLedger) -> Void,
        schedule: @escaping Schedule,
        mergeDelay: TimeInterval = 0.4,
        retryDelay: TimeInterval = 1.5
    ) {
        self.backup = backup
        self.isEnabled = isEnabled
        self.hasPendingUpload = hasPendingUpload
        self.loadLedger = loadLedger
        self.persistLedger = persistLedger
        self.schedule = schedule
        self.mergeDelay = mergeDelay
        self.retryDelay = retryDelay
    }

    public func replaceBackup(_ backup: @escaping Backup) {
        replaceOperations(backup: backup, isEnabled: isEnabled, hasPendingUpload: hasPendingUpload)
    }

    public func replaceOperations(
        backup: @escaping Backup,
        isEnabled: @escaping () throws -> Bool,
        hasPendingUpload: @escaping () throws -> Bool
    ) {
        lock.lock()
        self.backup = backup
        self.isEnabled = isEnabled
        self.hasPendingUpload = hasPendingUpload
        lock.unlock()
    }

    public func noteSuccessfulChange() {
        mutateLedger { $0.noteChange() }
        scheduleMergedWork(delay: mergeDelay)
    }

    public func compensateOnLaunch() {
        lock.lock()
        halted = false
        lock.unlock()
        guard loadLedger().hasUnconfirmedChange || pendingUploadExists() else { return }
        scheduleMergedWork(delay: 0)
    }

    public static func dispatchQueueSchedule(
        queue: DispatchQueue = .global(qos: .utility)
    ) -> Schedule {
        { delay, work in
            let item = DispatchWorkItem(block: work)
            queue.asyncAfter(deadline: .now() + delay, execute: item)
            return Cancellation { item.cancel() }
        }
    }

    public func retire() {
        lock.lock()
        generation += 1
        halted = true
        let pending = self.pending
        self.pending = nil
        lock.unlock()
        pending?.cancel()
    }

    public func cancelPendingWork(clearDirty: Bool) {
        lock.lock()
        halted = true
        let pending = self.pending
        self.pending = nil
        lock.unlock()
        pending?.cancel()
        if clearDirty {
            mutateLedger { $0.confirmAll() }
        }
    }

    public func resumeScheduling() {
        lock.lock()
        halted = false
        let writing = self.writing
        lock.unlock()
        if writing { return }
        if loadLedger().hasUnconfirmedChange || pendingUploadExists() {
            scheduleMergedWork(delay: 0)
        }
    }

    @discardableResult
    private func mutateLedger(
        _ body: (inout AutomaticBackupChangeLedger) -> Void
    ) -> AutomaticBackupChangeLedger {
        lock.lock()
        defer { lock.unlock() }
        var ledger = loadLedger()
        body(&ledger)
        persistLedger(ledger)
        return ledger
    }

    private func pendingUploadExists() -> Bool {
        do {
            return try hasPendingUpload()
        } catch {
            return false
        }
    }

    private func scheduleMergedWork(delay: TimeInterval) {
        lock.lock()
        if halted {
            lock.unlock()
            return
        }
        pending?.cancel()
        pending = schedule(delay) { [weak self] in
            self?.runScheduledBackup()
        }
        lock.unlock()
    }

    private func runScheduledBackup() {
        lock.lock()
        if halted || writing {
            lock.unlock()
            return
        }
        let startedVersion = loadLedger().changeVersion
        let pendingAtStart = pendingUploadExists()
        do {
            guard try isEnabled() else {
                lock.unlock()
                return
            }
        } catch {
            lastError = error
            lock.unlock()
            retryIfTransient(error)
            return
        }
        guard loadLedger().hasUnconfirmedChange || pendingAtStart else {
            lock.unlock()
            return
        }
        writing = true
        let backup = self.backup
        let startGeneration = generation
        lock.unlock()

        do {
            let generationResult = try backup()
            finishWrite(
                startGeneration: startGeneration,
                startedVersion: startedVersion,
                pendingAtStart: pendingAtStart,
                result: .success(generationResult)
            )
        } catch {
            finishWrite(
                startGeneration: startGeneration,
                startedVersion: startedVersion,
                pendingAtStart: pendingAtStart,
                result: .failure(error)
            )
        }
    }

    private func finishWrite(
        startGeneration: Int,
        startedVersion: Int,
        pendingAtStart: Bool,
        result: Result<ICloudBackupGeneration, Error>
    ) {
        lock.lock()
        writing = false
        let retired = generation != startGeneration
        switch result {
        case .success(let value):
            if !retired {
                lastGeneration = value
                lastError = nil
            }
            if !retired {
                var ledger = loadLedger()
                if !(pendingAtStart && startedVersion > ledger.confirmedVersion) {
                    ledger.confirm(upTo: startedVersion)
                    persistLedger(ledger)
                }
            }
            let needsAnother = loadLedger().hasUnconfirmedChange || pendingUploadExists()
            let halted = self.halted
            lock.unlock()
            if !retired, !halted, needsAnother {
                scheduleMergedWork(delay: mergeDelay)
            }
        case .failure(let error):
            if !retired {
                lastError = error
            }
            lock.unlock()
            if retired { return }
            if blocksFurtherWrites(error) { return }
            retryIfTransient(error)
        }
    }

    private func retryIfTransient(_ error: Error) {
        if blocksFurtherWrites(error) { return }
        lock.lock()
        let halted = self.halted
        lock.unlock()
        if halted { return }
        scheduleMergedWork(delay: retryDelay)
    }

    private func blocksFurtherWrites(_ error: Error) -> Bool {
        if let backupError = error as? ICloudBackupError {
            switch backupError {
            case .propagationPending, .containerUnavailable, .cleanupFailed:
                return false
            case .automaticBackupPaused, .conflictCopy, .differentWriter, .forkDetected,
                 .capabilityUnavailable, .authenticationRequired, .invalidRecoveryKey,
                 .invalidPendingUpload, .invalidCleanupState, .invalidSnapshot,
                 .noValidGeneration, .invalidGeneration, .randomGenerationFailed,
                 .keyMaterialReadFailed, .keyMaterialWriteFailed:
                return true
            }
        }
        if let vaultError = error as? VaultError, case .agentAccessPaused = vaultError {
            return true
        }
        return false
    }
}
