import AskKeyDevices
import CloudKit
import CryptoKit
import Foundation

/// A device identity with software P-256 keys, for tests only. It counts
/// every use of the approval key, which the extension must never make, and
/// can stop working as a key that no longer opens would.
final class TestIdentity: DeviceIdentity, @unchecked Sendable {
    private let messageKey = P256.Signing.PrivateKey()
    private let agreementKey = P256.KeyAgreement.PrivateKey()
    private let approvalKey = P256.Signing.PrivateKey()
    private let lock = NSLock()
    private var approvalUses = 0
    private var broken = false

    var messagePublicKey: P256.Signing.PublicKey { messageKey.publicKey }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { agreementKey.publicKey }
    var approvalPublicKey: P256.Signing.PublicKey { approvalKey.publicKey }
    var id: DeviceID { DeviceID(messagePublicKey: messagePublicKey) }

    var approvalKeyUses: Int { lock.withLock { approvalUses } }

    var isUnusable: Bool {
        get { lock.withLock { broken } }
        set { lock.withLock { broken = newValue } }
    }

    /// Stand-in key blobs: the extension only checks that all three exist.
    var blobs: DeviceIdentityKeyBlobs {
        DeviceIdentityKeyBlobs(message: messagePublicKey.compressedRepresentation,
                               agreement: agreementPublicKey.compressedRepresentation,
                               approval: approvalPublicKey.compressedRepresentation)
    }

    func signWithMessageKey(_ data: Data) throws -> Data {
        guard !isUnusable else { throw DeviceIdentityError.unusable }
        return try messageKey.signature(for: data).rawRepresentation
    }

    func signWithApprovalKey(_ data: Data, reason: String) async throws -> Data {
        lock.withLock { approvalUses += 1 }
        return try approvalKey.signature(for: data).rawRepresentation
    }

    func openHPKE(_ ciphertext: Data, encapsulatedKey: Data, info: Data,
                  preSharedKey: HPKEPreSharedKey?) throws -> Data {
        guard !isUnusable else { throw DeviceIdentityError.unusable }
        var recipient: HPKE.Recipient
        if let preSharedKey {
            recipient = try HPKE.Recipient(privateKey: agreementKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: info,
                                           encapsulatedKey: encapsulatedKey, presharedKey: preSharedKey.key,
                                           presharedKeyIdentifier: preSharedKey.identifier)
        } else {
            recipient = try HPKE.Recipient(privateKey: agreementKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: info,
                                           encapsulatedKey: encapsulatedKey)
        }
        return try recipient.open(ciphertext)
    }
}

final class TestClock: DeviceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date { lock.withLock { current } }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}

/// The shared keychain group in memory. It records every write and
/// deletion, and its reads can fail as before the first unlock.
final class TestKeychain: SecureItemStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var written: [String] = []
    private var deleted: [String] = []
    private var failingReads = false
    private var failingWrites = false

    /// Accounts written, in order, setup excluded.
    var writes: [String] { lock.withLock { written } }
    var deletions: [String] { lock.withLock { deleted } }

    var readsFail: Bool {
        get { lock.withLock { failingReads } }
        set { lock.withLock { failingReads = newValue } }
    }

    var writesFail: Bool {
        get { lock.withLock { failingWrites } }
        set { lock.withLock { failingWrites = newValue } }
    }

    /// Stores an item as the app would, without recording it as a write.
    func seed(_ data: Data?, for account: String) {
        lock.withLock { items[account] = data }
    }

    func stored(_ account: String) -> Data? { lock.withLock { items[account] } }

    func data(for account: String) throws -> Data? {
        try lock.withLock {
            if failingReads { throw KeychainError(status: errSecInteractionNotAllowed) }
            return items[account]
        }
    }

    func setData(_ data: Data, for account: String) throws {
        try lock.withLock {
            if failingWrites { throw KeychainError(status: errSecInteractionNotAllowed) }
            written.append(account)
            items[account] = data
        }
    }

    func deleteData(for account: String) throws {
        lock.withLock {
            deleted.append(account)
            items[account] = nil
        }
    }
}

final class TestListStore: PairedDeviceListStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    init(_ list: PairedDeviceList) throws {
        stored = try list.serialized()
    }

    func loadPairedDeviceList() throws -> PairedDeviceList {
        guard let data = lock.withLock({ stored }) else { return PairedDeviceList() }
        return try PairedDeviceList(serialized: data)
    }

    func savePairedDeviceList(_ list: PairedDeviceList) throws {
        let data = try list.serialized()
        lock.withLock { stored = data }
    }
}

/// Lets a test hold a CloudKit call until it opens the gate.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0

    /// How many calls reached the gate.
    var arrived: Int { lock.withLock { arrivals } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume: Bool = lock.withLock {
                arrivals += 1
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}

/// The account's private database in memory, behind the same protocol the
/// real CloudKit calls use, so the extension's transport runs unchanged.
/// Every call is logged with the zone it touched.
final class TestCloudKit: CloudKitInboxService, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CKRecord.ID: CKRecord] = [:]
    private var log: [String] = []
    private var missingZone = false
    private var failingFetches = false
    private var failingRecords = false
    private var failingSends = false
    private var gate: Gate?

    var calls: [String] { lock.withLock { log } }

    /// The phone's inbox zone answers as deleted.
    var zoneMissing: Bool {
        get { lock.withLock { missingZone } }
        set { lock.withLock { missingZone = newValue } }
    }

    var fetchesFail: Bool {
        get { lock.withLock { failingFetches } }
        set { lock.withLock { failingFetches = newValue } }
    }

    /// CloudKit answers each record with an error instead of the record.
    var recordsFail: Bool {
        get { lock.withLock { failingRecords } }
        set { lock.withLock { failingRecords = newValue } }
    }

    var sendsFail: Bool {
        get { lock.withLock { failingSends } }
        set { lock.withLock { failingSends = newValue } }
    }

    /// Holds record fetches until the gate opens.
    var fetchGate: Gate? {
        get { lock.withLock { gate } }
        set { lock.withLock { gate = newValue } }
    }

    /// The envelopes stored in a device's inbox.
    func envelopes(in device: DeviceID) -> [DeviceEnvelope] {
        let zone = CloudKitInboxLayout.zoneName(for: device)
        return lock.withLock { records.values.filter { $0.recordID.zoneID.zoneName == zone } }
            .compactMap(CloudKitMessageRecord.envelope(from:))
    }

    func insert(_ envelope: DeviceEnvelope) throws {
        let record = try CloudKitMessageRecord.record(for: envelope)
        lock.withLock { records[record.recordID] = record }
    }

    private func note(_ call: String, _ zone: String = "") {
        lock.withLock { log.append(zone.isEmpty ? call : "\(call) \(zone)") }
    }

    func accountStatus() async throws -> CKAccountStatus {
        note("accountStatus")
        return .available
    }

    func userRecordName() async throws -> String {
        note("userRecordName")
        return "_synthetic_user"
    }

    func zoneExists(_ zoneID: CKRecordZone.ID) async throws -> Bool {
        note("zoneExists", zoneID.zoneName)
        return true
    }

    func saveZone(_ zoneID: CKRecordZone.ID) async throws { note("saveZone", zoneID.zoneName) }

    func deleteZone(_ zoneID: CKRecordZone.ID) async throws { note("deleteZone", zoneID.zoneName) }

    func fetchSubscriptions(_ ids: [CKSubscription.ID]) async throws -> [CKSubscription.ID: Result<CKSubscription, Error>] {
        note("fetchSubscriptions")
        return [:]
    }

    func saveSubscription(_ subscription: CKSubscription) async throws { note("saveSubscription") }

    func deleteSubscriptions(_ ids: [CKSubscription.ID]) async throws -> [CKSubscription.ID: Result<Void, Error>] {
        note("deleteSubscriptions")
        return [:]
    }

    func createRecord(_ record: CKRecord) async throws {
        note("createRecord", record.recordID.zoneID.zoneName)
        try lock.withLock {
            if failingSends { throw CKError(.networkFailure) }
            if records[record.recordID] != nil { throw CKError(.serverRecordChanged) }
            records[record.recordID] = record
        }
    }

    func deleteRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<Void, Error>] {
        note("deleteRecords", ids.first?.zoneID.zoneName ?? "")
        return lock.withLock {
            var results: [CKRecord.ID: Result<Void, Error>] = [:]
            for id in ids {
                records[id] = nil
                results[id] = .success(())
            }
            return results
        }
    }

    func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        note("fetchRecords", ids.first?.zoneID.zoneName ?? "")
        await fetchGate?.wait()
        return try lock.withLock {
            if missingZone { throw CKError(.zoneNotFound) }
            if failingFetches { throw CKError(.networkUnavailable) }
            var results: [CKRecord.ID: Result<CKRecord, Error>] = [:]
            for id in ids {
                if failingRecords {
                    results[id] = .failure(CKError(.serviceUnavailable))
                } else {
                    results[id] = records[id].map { .success($0) } ?? .failure(CKError(.unknownItem))
                }
            }
            return results
        }
    }

    func fetchChanges(in zoneID: CKRecordZone.ID, since token: Data?) async throws -> CloudKitZoneChanges {
        note("fetchChanges", zoneID.zoneName)
        let found = lock.withLock { records.values.filter { $0.recordID.zoneID == zoneID } }
        return CloudKitZoneChanges(records: found.sorted { $0.recordID.recordName < $1.recordID.recordName },
                                   token: Data([1]))
    }
}
