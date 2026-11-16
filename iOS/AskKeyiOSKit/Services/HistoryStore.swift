import CryptoKit
import Foundation
import Security

/// One request this app verified, as History keeps it (ADR 0014 → iPhone
/// app → History, amended by #345): the four names a detailed notification
/// shows, the times and the outcome, plus what identifies the entry and
/// checks a late closed message. Never the command line, the working
/// directory, the delivered names, the purpose, a credential value or the
/// envelope.
struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    /// The request's record name. It identifies nothing, because a sender
    /// chooses it; it only finds the entry of an open request page.
    var recordName: String
    var macID: String
    var pairingID: Data
    var requestDigest: Data
    /// Empty means Local Agent.
    var requesterName: String
    var credentialName: String
    var executableName: String
    /// This iPhone's name for the Mac when the request ended.
    var macName: String
    /// When the app first verified the request, on this iPhone's clock.
    var receivedAt: Date
    /// The countdown's stored end, on this iPhone's clock.
    var countdownEnd: Date
    /// Nil while the request is in progress; History shows only completed entries.
    var endedAt: Date?
    /// The decision this iPhone sent, if any, and its signed duration ceiling.
    var decisionCode: UInt8?
    var decisionCeiling: UInt64
    /// The Mac's closed message, when one ended the request.
    var closed: StoredClosed?
    /// A later launch time of the Mac App ended it. A completed entry with
    /// neither a closed message nor this timed out.
    var gone: Bool

    /// The Mac's device ID, the pairing ID and the request digest: at most
    /// one entry has each.
    var id: String { Self.identity(macID: macID, pairingID: pairingID, requestDigest: requestDigest) }

    static func identity(macID: String, pairingID: Data, requestDigest: Data) -> String {
        "\(macID)/\(pairingID.base64EncodedString())/\(requestDigest.base64EncodedString())"
    }

    var isCompleted: Bool { endedAt != nil }

    /// How it ended, with the outcome page's symbol and color; nil while open.
    var ending: RequestEnding? {
        guard isCompleted else { return nil }
        if let closed, let outcome = RequestOutcome(closed) { return .closed(outcome) }
        return gone ? .gone : .timedOut
    }

    /// A timed-out or gone outcome, which a late closed message may correct.
    var isUnconfirmed: Bool { isCompleted && closed == nil }
}

/// The history file's content: open and completed entries.
struct StoredHistory: Codable, Hashable, Sendable {
    /// Completed entries are kept this long after they ended...
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    /// ...and at most this many, the oldest dropped first.
    static let limit = 500

    var version = 1
    var entries: [HistoryEntry] = []

    func index(of id: String) -> Int? {
        entries.firstIndex { $0.id == id }
    }

    /// Drops completed entries that ended 30 days or more before `now`, then
    /// the oldest completed entries beyond 500. Open entries stay.
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        entries.removeAll { entry in entry.endedAt.map { $0 <= cutoff } ?? false }
        let completed = entries.compactMap(\.endedAt)
        guard completed.count > Self.limit else { return }
        let dropped = Set(entries.filter(\.isCompleted).sorted { $0.endedAt! < $1.endedAt! }
            .prefix(completed.count - Self.limit).map(\.id))
        entries.removeAll { dropped.contains($0.id) }
    }
}

// MARK: Storage

/// Where the history's encrypted bytes live: its own directory of the app's
/// container, never the notification extension's reach.
public protocol HistoryFileStore: AnyObject {
    /// Nil when no history is stored. Throws when it cannot be read now.
    func loadHistory() throws -> Data?
    func saveHistory(_ data: Data) throws
    /// Deleting a history that does not exist succeeds.
    func removeHistory() throws
    /// A deletion that did not finish, kept across launches so it is tried
    /// again before the file is read.
    var isDeletionPending: Bool { get }
    func setDeletionPending(_ pending: Bool) throws
}

public final class FileHistoryStore: HistoryFileStore {
    /// The request store's data protection: entries are written while the
    /// app runs in the background on a locked phone.
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    let directory: URL
    private let file: URL
    private let marker: URL

    /// `base` is the app's Application Support directory by default; the
    /// history lives in its own `History` directory, excluded from backups.
    public init(base: URL? = nil) {
        let base = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("History", isDirectory: true)
        file = directory.appendingPathComponent("history")
        marker = directory.appendingPathComponent("deletion-pending")
    }

    public func loadHistory() throws -> Data? {
        do {
            return try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    public func saveHistory(_ data: Data) throws {
        try prepareDirectory()
        try data.write(to: file, options: Self.writeOptions)
    }

    public func removeHistory() throws {
        try Self.remove(file)
    }

    public var isDeletionPending: Bool {
        FileManager.default.fileExists(atPath: marker.path)
    }

    public func setDeletionPending(_ pending: Bool) throws {
        if pending {
            try prepareDirectory()
            try Data().write(to: marker, options: Self.writeOptions)
        } else {
            try Self.remove(marker)
        }
    }

    /// Creates the directory and excludes it, and so the file, from backups.
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
    }

    private static func remove(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}

/// The history's 256-bit key.
public protocol HistoryKeyStore: AnyObject {
    /// Nil when no key is stored. Throws when it cannot be read now.
    func loadKey() throws -> Data?
    func saveKey(_ key: Data) throws
    /// Deleting a key that does not exist succeeds.
    func deleteKey() throws
}

/// The key in a keychain item of the app's own access group, its
/// application identifier, which the notification extension does not hold:
/// accessible after first unlock, this device only, never synchronized.
/// Without that group nothing is stored, because the default group is the
/// one the extension shares.
public final class KeychainHistoryKeyStore: HistoryKeyStore {
    public static let service = "com.sudohg.askkey.ios.history"
    static let account = "history-key"
    static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    private let service: String
    private let accessGroup: String?

    public init(service: String = KeychainHistoryKeyStore.service, accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// The group is `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`,
    /// read from the Info.plist key `HistoryKeychainAccessGroup`.
    public convenience init(bundle: Bundle = .main) {
        let group = (bundle.object(forInfoDictionaryKey: "HistoryKeychainAccessGroup") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        self.init(accessGroup: group)
    }

    /// The item's identifying attributes; nil without the app's own group.
    func query() -> [CFString: Any]? {
        guard let accessGroup else { return nil }
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: Self.account,
            kSecAttrAccessGroup: accessGroup,
            kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
    }

    /// Everything a new item is added with.
    func addition(_ key: Data) -> [CFString: Any]? {
        query()?.merging([kSecValueData: key, kSecAttrAccessible: Self.accessibility]) { $1 }
    }

    public func loadKey() throws -> Data? {
        guard var request = query() else { throw KeychainError(status: errSecMissingEntitlement) }
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return data
    }

    public func saveKey(_ key: Data) throws {
        guard let query = query(), let addition = addition(key) else { throw KeychainError(status: errSecMissingEntitlement) }
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw KeychainError(status: deleted) }
        let added = SecItemAdd(addition as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    public func deleteKey() throws {
        // Without the group nothing was ever stored.
        guard let query = query() else { return }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// The history on disk: one AES-GCM box under the key, with the iCloud
/// account's user record name as authenticated data, so a file bound to
/// another account, or one the key cannot open, fails to open and is deleted
/// unread.
struct EncryptedHistory {
    static let formatVersion: UInt8 = 1
    let files: any HistoryFileStore
    let keys: any HistoryKeyStore

    static func authenticatedData(account: String) -> Data {
        Data("com.sudohg.askkey.ios.history.v1\n\(account)".utf8)
    }

    /// The stored history, or an empty one when none is stored or it does
    /// not open. Nil when it cannot be read now, or an earlier deletion
    /// still fails: the caller then writes nothing over it.
    func load(account: String) -> StoredHistory? {
        if files.isDeletionPending {
            do {
                try delete()
            } catch {
                AppLog.failure("Deleting the history", error)
                return nil
            }
        }
        let data: Data?
        let key: Data?
        do {
            data = try files.loadHistory()
            key = try data == nil ? nil : keys.loadKey()
        } catch {
            AppLog.failure("Reading the history", error)
            return nil
        }
        guard let data else { return StoredHistory() }
        guard let key, let history = Self.open(data, key: key, account: account) else {
            discardUnreadable()
            return StoredHistory()
        }
        return history
    }

    static func open(_ data: Data, key: Data, account: String) -> StoredHistory? {
        guard key.count == 32, data.first == formatVersion,
              let box = try? AES.GCM.SealedBox(combined: data.dropFirst()),
              let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: key),
                                                authenticating: authenticatedData(account: account)),
              let history = try? JSONDecoder().decode(StoredHistory.self, from: plaintext), history.version == 1 else {
            return nil
        }
        return history
    }

    /// Seals and writes the history, creating a key when none is stored.
    func save(_ history: StoredHistory, account: String) throws {
        let key: Data
        if let stored = try keys.loadKey(), stored.count == 32 {
            key = stored
        } else {
            key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try keys.saveKey(key)
        }
        let plaintext = try JSONEncoder().encode(history)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key),
                                   authenticating: Self.authenticatedData(account: account))
        guard let combined = box.combined else { throw CocoaError(.coderInvalidValue) }
        try files.saveHistory(Data([Self.formatVersion]) + combined)
    }

    /// Deletes the key, then the file, so a file whose deletion failed can
    /// no longer be opened. Until both are gone the deletion stays pending
    /// on disk and is tried again before the file is read.
    func delete() throws {
        do {
            try files.setDeletionPending(true)
        } catch {
            AppLog.failure("Marking the history for deletion", error)
        }
        try keys.deleteKey()
        try files.removeHistory()
        try files.setDeletionPending(false)
    }

    /// A file that does not open goes, and with it the key that cannot open
    /// it; the next save creates a new key.
    private func discardUnreadable() {
        do {
            try files.removeHistory()
            try keys.deleteKey()
        } catch {
            AppLog.failure("Deleting an unreadable history", error)
        }
    }
}
