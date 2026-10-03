import Foundation

public enum LocalVaultEraseState: String, Codable, Equatable, Sendable {
    case confirmed
    case operationsQuiesced
    case deliveriesCleared
    // Decode the former checkpoint so interrupted local erases still recover.
    case backupsStopped
    case dataDeleted
    case keyDeleted
}

public enum LocalVaultEraseError: Error, Equatable, LocalizedError {
    case authenticationRequired
    case confirmationMismatch
    case invalidJournal

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Erasing Ask Key requires system authentication."
        case .confirmationMismatch:
            return "The erase confirmation text did not match."
        case .invalidJournal:
            return "Ask Key found an invalid local erase journal and stopped safely."
        }
    }
}

public protocol LocalVaultEraseJournalStore: AnyObject {
    func load() throws -> LocalVaultEraseState?
    func save(_ state: LocalVaultEraseState) throws
    func clear() throws
}

public final class FileLocalVaultEraseJournalStore: LocalVaultEraseJournalStore {
    private let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func load() throws -> LocalVaultEraseState? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LocalVaultEraseError.invalidJournal
        }
        do {
            return try JSONDecoder().decode(LocalVaultEraseState.self, from: Data(contentsOf: url))
        } catch {
            throw LocalVaultEraseError.invalidJournal
        }
    }

    public func save(_ state: LocalVaultEraseState) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    public func clear() throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}

public struct LocalVaultEraseActions: Sendable {
    let quiesceOperations: @Sendable () throws -> Void
    let cleanupDeliveries: @Sendable () throws -> Void
    let deleteEncryptedData: @Sendable () throws -> Void
    let deleteLocalKey: @Sendable () throws -> Void

    public init(
        quiesceOperations: @escaping @Sendable () throws -> Void,
        cleanupDeliveries: @escaping @Sendable () throws -> Void,
        deleteEncryptedData: @escaping @Sendable () throws -> Void,
        deleteLocalKey: @escaping @Sendable () throws -> Void
    ) {
        self.quiesceOperations = quiesceOperations
        self.cleanupDeliveries = cleanupDeliveries
        self.deleteEncryptedData = deleteEncryptedData
        self.deleteLocalKey = deleteLocalKey
    }
}

public enum LocalVaultEraseLanguage: Sendable {
    case simplifiedChinese
    case english

    public var confirmationText: String {
        switch self {
        case .simplifiedChinese: return "抹除"
        case .english: return "ERASE"
        }
    }
}

public final class LocalVaultEraseCoordinator: @unchecked Sendable {
    private let journal: LocalVaultEraseJournalStore
    private let actions: LocalVaultEraseActions
    private let lock = NSLock()

    public init(journal: LocalVaultEraseJournalStore, actions: LocalVaultEraseActions) {
        self.journal = journal
        self.actions = actions
    }

    public func erase(
        confirmation: String,
        language: LocalVaultEraseLanguage,
        using authenticator: ManagementAuthenticator
    ) throws {
        guard authenticator.confirm(reason: "Erase the local Ask Key vault") else {
            throw LocalVaultEraseError.authenticationRequired
        }
        guard confirmation == language.confirmationText else {
            throw LocalVaultEraseError.confirmationMismatch
        }
        lock.lock()
        defer { lock.unlock() }
        if try journal.load() == nil {
            try journal.save(.confirmed)
        }
        try recoverForward()
    }

    /// A persisted erase authorization recovers forward without prompting again.
    /// Every action is required to be idempotent because a process can terminate
    /// after the action succeeds but before the next state is persisted.
    public func recoverIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        guard try journal.load() != nil else { return }
        try recoverForward()
    }

    private func recoverForward() throws {
        while let state = try journal.load() {
            switch state {
            case .confirmed:
                try actions.quiesceOperations()
                try journal.save(.operationsQuiesced)
            case .operationsQuiesced:
                try actions.cleanupDeliveries()
                try journal.save(.deliveriesCleared)
            case .deliveriesCleared, .backupsStopped:
                try actions.deleteEncryptedData()
                try journal.save(.dataDeleted)
            case .dataDeleted:
                try actions.deleteLocalKey()
                try journal.save(.keyDeleted)
            case .keyDeleted:
                try journal.clear()
            }
        }
    }
}
