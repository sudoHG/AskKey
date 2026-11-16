import AskKeyDevices
import Foundation
import XCTest
@testable import AskKeyiOSKit

/// The history file in memory; reads, writes and deletions can be made to fail.
final class InMemoryHistoryFiles: HistoryFileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var pending = false
    private var failWrites = false
    private var failReads = false
    private var failRemovals = false

    /// The stored bytes, as the file would hold them.
    var storedData: Data? {
        get { lock.withLock { data } }
        set { lock.withLock { data = newValue } }
    }

    var writesFail: Bool {
        get { lock.withLock { failWrites } }
        set { lock.withLock { failWrites = newValue } }
    }

    var readsFail: Bool {
        get { lock.withLock { failReads } }
        set { lock.withLock { failReads = newValue } }
    }

    var removalsFail: Bool {
        get { lock.withLock { failRemovals } }
        set { lock.withLock { failRemovals = newValue } }
    }

    func loadHistory() throws -> Data? {
        try lock.withLock {
            if failReads { throw CocoaError(.fileReadUnknown) }
            return data
        }
    }

    func saveHistory(_ data: Data) throws {
        try lock.withLock {
            if failWrites { throw CocoaError(.fileWriteNoPermission) }
            self.data = data
        }
    }

    func removeHistory() throws {
        try lock.withLock {
            if failRemovals { throw CocoaError(.fileWriteNoPermission) }
            data = nil
        }
    }

    var isDeletionPending: Bool { lock.withLock { pending } }

    func setDeletionPending(_ pending: Bool) throws {
        lock.withLock { self.pending = pending }
    }
}

/// The history key in memory; deletions can be made to fail.
final class InMemoryHistoryKeys: HistoryKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    private var failDeletes = false

    var storedKey: Data? {
        get { lock.withLock { key } }
        set { lock.withLock { key = newValue } }
    }

    var deletesFail: Bool {
        get { lock.withLock { failDeletes } }
        set { lock.withLock { failDeletes = newValue } }
    }

    func loadKey() throws -> Data? { storedKey }

    func saveKey(_ key: Data) throws { storedKey = key }

    func deleteKey() throws {
        try lock.withLock {
            if failDeletes { throw KeychainError(status: errSecInteractionNotAllowed) }
            key = nil
        }
    }
}

extension TestWorld {
    /// The account the history is bound to.
    var historyAccount: String { localState.inboxPosition?.userRecordName ?? "" }

    var historyStorage: EncryptedHistory { EncryptedHistory(files: historyFiles, keys: historyKeys) }

    /// The history file opened with the stored key under the current
    /// account; nil when there is none or it does not open.
    var storedHistory: StoredHistory? {
        guard let data = historyFiles.storedData, let key = historyKeys.storedKey else { return nil }
        return EncryptedHistory.open(data, key: key, account: historyAccount)
    }

    /// The decrypted history file's bytes.
    var storedHistoryPlaintext: Data? {
        storedHistory.flatMap { try? JSONEncoder().encode($0) }
    }

    /// A completed entry for a synthetic request.
    static func historyEntry(mac: String = "mac", recordName: String = UUID().uuidString, credential: String = "GitHub Token",
                             endedAt: Date, closed: StoredClosed? = nil) -> HistoryEntry {
        HistoryEntry(recordName: recordName, macID: mac, pairingID: Data(repeating: 1, count: 16),
                     requestDigest: Data(UUID().uuidString.utf8), requesterName: "Codex", credentialName: credential,
                     executableName: "deploy.sh", macName: TestWorld.macName, receivedAt: endedAt.addingTimeInterval(-30),
                     countdownEnd: endedAt.addingTimeInterval(270), endedAt: endedAt, decisionCode: nil,
                     decisionCeiling: 0, closed: closed, gone: false)
    }

    /// Writes a history file as an earlier launch would have.
    func storeHistory(_ entries: [HistoryEntry], account: String? = nil) throws {
        try historyStorage.save(StoredHistory(entries: entries), account: account ?? historyAccount)
    }

    /// The app launched again on the same storage.
    func relaunch() async -> AppModel {
        let relaunched = AppModel(environment: environment)
        await relaunched.start()
        return relaunched
    }
}

extension StoredClosed {
    /// A closed outcome as the store keeps it, for synthetic entries.
    static func fixture(_ outcome: ApprovalClosedOutcome, code: ApprovalDecisionCode? = nil,
                        duration: UInt64 = 0) -> StoredClosed {
        struct Raw: Encodable {
            let outcome: UInt8
            let appliedCode: UInt8?
            let appliedDuration: UInt64
        }
        let data = try! JSONEncoder().encode(Raw(outcome: outcome.rawValue, appliedCode: code?.rawValue,
                                                 appliedDuration: duration))
        return try! JSONDecoder().decode(StoredClosed.self, from: data)
    }
}
