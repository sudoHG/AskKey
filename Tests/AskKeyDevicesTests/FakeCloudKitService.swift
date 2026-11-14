@testable import AskKeyDevices
import CloudKit
import Foundation

/// Stands in for the CloudKit calls of one account, in memory, without a
/// container: zones, records with per-zone change tokens, subscriptions and
/// the account. Fetched subscriptions come back as CloudKit returns them:
/// the zone owner resolved to the user record name and the desired keys in
/// another order. Tests can play a writer to the same account and inject
/// CloudKit errors.
final class FakeCloudKitService: CloudKitInboxService, @unchecked Sendable {
    private struct Stored {
        let record: CKRecord
        let sequence: Int
    }

    private let lock = NSLock()
    private var zones: Set<String> = []
    private var records: [String: [String: Stored]] = [:]
    private var subscriptions: [CKSubscription.ID: CKSubscription] = [:]
    private var sequence = 0
    private var generations: [String: UInt64] = [:]
    private var savedSubscriptions: [CKSubscription.ID] = []
    private var savedZones: [String] = []
    private var subscriptionFetches = 0
    private var created: [CKRecord] = []
    private var deleteBatches: [Int] = []
    private var fetchBatches: [[String]] = []

    // Injected behavior; set before the call it affects.
    var subscriptionFetchError: Error? { get { locked { _subscriptionFetchError } } set { locked { _subscriptionFetchError = newValue } } }
    var subscriptionAnswers: [CKSubscription.ID: Error] { get { locked { _subscriptionAnswers } } set { locked { _subscriptionAnswers = newValue } } }
    var subscriptionSaveErrors: [CKSubscription.ID: Error] { get { locked { _subscriptionSaveErrors } } set { locked { _subscriptionSaveErrors = newValue } } }
    var zoneSaveError: Error? { get { locked { _zoneSaveError } } set { locked { _zoneSaveError = newValue } } }
    var unreadableRecordNames: Set<String> { get { locked { _unreadable } } set { locked { _unreadable = newValue } } }
    var recordDeleteErrors: [String: Error] { get { locked { _recordDeleteErrors } } set { locked { _recordDeleteErrors = newValue } } }
    var nextCreateErrors: [Error] { get { locked { _nextCreateErrors } } set { locked { _nextCreateErrors = newValue } } }
    var pageSize: Int? { get { locked { _pageSize } } set { locked { _pageSize = newValue } } }
    var recordFetchErrors: [String: Error] { get { locked { _recordFetchErrors } } set { locked { _recordFetchErrors = newValue } } }
    /// Fails every record fetch request as a whole, until set to nil.
    var recordFetchError: Error? { get { locked { _recordFetchError } } set { locked { _recordFetchError = newValue } } }
    var status: CKAccountStatus { get { locked { _status } } set { locked { _status = newValue } } }
    var statusError: Error? { get { locked { _statusError } } set { locked { _statusError = newValue } } }
    var userRecordNameValue: String { get { locked { _userRecordName } } set { locked { _userRecordName = newValue } } }
    /// Runs at the start of each subscription fetch, for example to let time pass.
    var duringSubscriptionFetch: (@Sendable () -> Void)? { get { locked { _duringSubscriptionFetch } } set { locked { _duringSubscriptionFetch = newValue } } }

    private var _subscriptionFetchError: Error?
    private var _subscriptionAnswers: [CKSubscription.ID: Error] = [:]
    private var _subscriptionSaveErrors: [CKSubscription.ID: Error] = [:]
    private var _zoneSaveError: Error?
    private var _unreadable: Set<String> = []
    private var _recordDeleteErrors: [String: Error] = [:]
    private var _nextCreateErrors: [Error] = []
    private var _pageSize: Int?
    private var _recordFetchErrors: [String: Error] = [:]
    private var _recordFetchError: Error?
    private var _status: CKAccountStatus = .available
    private var _statusError: Error?
    private var _userRecordName = "_4d1f0c2a"
    private var _duringSubscriptionFetch: (@Sendable () -> Void)?

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock(body)
    }

    // MARK: What the transport did

    var savedSubscriptionIDs: [CKSubscription.ID] { locked { savedSubscriptions } }
    var savedZoneNames: [String] { locked { savedZones } }
    var subscriptionFetchCount: Int { locked { subscriptionFetches } }
    var createdRecords: [CKRecord] { locked { created } }
    var zoneNames: Set<String> { locked { zones } }
    var deleteBatchSizes: [Int] { locked { deleteBatches } }
    /// The record names of each fetch-by-ID request.
    var recordFetchBatches: [[String]] { locked { fetchBatches } }

    // MARK: A writer to the same account

    func storedSubscription(_ id: CKSubscription.ID) -> CKSubscription? { locked { subscriptions[id] } }

    func putSubscription(_ subscription: CKSubscription) {
        locked { subscriptions[subscription.subscriptionID] = subscription }
    }

    func removeSubscription(_ id: CKSubscription.ID) {
        locked { _ = subscriptions.removeValue(forKey: id) }
    }

    func addZone(named name: String) {
        locked { _ = zones.insert(name) }
    }

    func removeZone(named name: String) {
        locked {
            zones.remove(name)
            records[name] = nil
        }
    }

    /// Writes a record into its zone, replacing one with the same name.
    func insert(_ record: CKRecord) {
        locked {
            sequence += 1
            records[record.recordID.zoneID.zoneName, default: [:]][record.recordID.recordName] = Stored(record: record,
                                                                                                         sequence: sequence)
        }
    }

    func removeRecord(named name: String, fromZone zone: String) {
        locked { _ = records[zone]?.removeValue(forKey: name) }
    }

    /// The records in a zone, oldest change first.
    func records(inZone zone: String) -> [CKRecord] {
        locked { (records[zone] ?? [:]).values.sorted { $0.sequence < $1.sequence }.map(\.record) }
    }

    func expireTokens(ofZone zone: String) {
        locked { generations[zone, default: 0] += 1 }
    }

    // MARK: CloudKitInboxService

    func accountStatus() async throws -> CKAccountStatus {
        try locked {
            if let _statusError { throw _statusError }
            return _status
        }
    }

    func userRecordName() async throws -> String {
        locked { _userRecordName }
    }

    func zoneExists(_ zoneID: CKRecordZone.ID) async throws -> Bool {
        locked { zones.contains(zoneID.zoneName) }
    }

    func saveZone(_ zoneID: CKRecordZone.ID) async throws {
        try locked {
            savedZones.append(zoneID.zoneName)
            if let _zoneSaveError { throw _zoneSaveError }
            zones.insert(zoneID.zoneName)
        }
    }

    func deleteZone(_ zoneID: CKRecordZone.ID) async throws {
        try locked {
            guard zones.remove(zoneID.zoneName) != nil else { throw CKError(.zoneNotFound) }
            records[zoneID.zoneName] = nil
        }
    }

    func fetchSubscriptions(_ ids: [CKSubscription.ID]) async throws -> [CKSubscription.ID: Result<CKSubscription, Error>] {
        duringSubscriptionFetch?()
        return try locked {
            subscriptionFetches += 1
            if let _subscriptionFetchError { throw _subscriptionFetchError }
            var results: [CKSubscription.ID: Result<CKSubscription, Error>] = [:]
            for id in ids {
                if let error = _subscriptionAnswers[id] {
                    results[id] = .failure(error)
                } else if let stored = subscriptions[id] {
                    results[id] = .success(Self.asReturned(stored, owner: _userRecordName))
                } else {
                    results[id] = .failure(CKError(.unknownItem))
                }
            }
            return results
        }
    }

    func saveSubscription(_ subscription: CKSubscription) async throws {
        try locked {
            savedSubscriptions.append(subscription.subscriptionID)
            if let error = _subscriptionSaveErrors[subscription.subscriptionID] { throw error }
            subscriptions[subscription.subscriptionID] = subscription
        }
    }

    func deleteSubscriptions(_ ids: [CKSubscription.ID]) async throws -> [CKSubscription.ID: Result<Void, Error>] {
        locked {
            var results: [CKSubscription.ID: Result<Void, Error>] = [:]
            for id in ids {
                results[id] = subscriptions.removeValue(forKey: id) == nil ? .failure(CKError(.unknownItem)) : .success(())
            }
            return results
        }
    }

    func createRecord(_ record: CKRecord) async throws {
        try locked {
            created.append(record)
            if !_nextCreateErrors.isEmpty { throw _nextCreateErrors.removeFirst() }
            let zone = record.recordID.zoneID.zoneName
            guard zones.contains(zone) else { throw CKError(.zoneNotFound) }
            guard records[zone]?[record.recordID.recordName] == nil else { throw CKError(.serverRecordChanged) }
            sequence += 1
            records[zone, default: [:]][record.recordID.recordName] = Stored(record: record.copy() as! CKRecord,
                                                                             sequence: sequence)
        }
    }

    func deleteRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<Void, Error>] {
        locked {
            deleteBatches.append(ids.count)
            var results: [CKRecord.ID: Result<Void, Error>] = [:]
            for id in ids {
                let zone = id.zoneID.zoneName
                if let error = _recordDeleteErrors[id.recordName] {
                    results[id] = .failure(error)
                } else if !zones.contains(zone) {
                    results[id] = .failure(CKError(.zoneNotFound))
                } else if records[zone]?.removeValue(forKey: id.recordName) == nil {
                    results[id] = .failure(CKError(.unknownItem))
                } else {
                    results[id] = .success(())
                }
            }
            return results
        }
    }

    func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        try locked {
            fetchBatches.append(ids.map(\.recordName))
            if let _recordFetchError { throw _recordFetchError }
            var results: [CKRecord.ID: Result<CKRecord, Error>] = [:]
            for id in ids {
                let zone = id.zoneID.zoneName
                if let error = _recordFetchErrors[id.recordName] {
                    results[id] = .failure(error)
                } else if !zones.contains(zone) {
                    results[id] = .failure(CKError(.zoneNotFound))
                } else if let stored = records[zone]?[id.recordName] {
                    results[id] = .success(stored.record)
                } else {
                    results[id] = .failure(CKError(.unknownItem))
                }
            }
            return results
        }
    }

    func fetchChanges(in zoneID: CKRecordZone.ID, since token: Data?) async throws -> CloudKitZoneChanges {
        try locked {
            let zone = zoneID.zoneName
            guard zones.contains(zone) else { throw CKError(.zoneNotFound) }
            let generation = generations[zone, default: 0]
            var after = 0
            if let token {
                guard token.count == 16, Self.integer(token.prefix(8)) == generation else {
                    throw CKError(.changeTokenExpired)
                }
                after = Int(Self.integer(token.suffix(8)))
            }
            let changed = (records[zone] ?? [:]).values.filter { $0.sequence > after }.sorted { $0.sequence < $1.sequence }
            let page = _pageSize.map { Array(changed.prefix($0)) } ?? changed
            let moreComing = page.count < changed.count
            let position = moreComing ? page.last!.sequence : sequence
            var newToken = withUnsafeBytes(of: generation.bigEndian) { Data($0) }
            withUnsafeBytes(of: UInt64(position).bigEndian) { newToken.append(contentsOf: $0) }
            return CloudKitZoneChanges(
                records: page.filter { !_unreadable.contains($0.record.recordID.recordName) }.map(\.record),
                failedRecordIDs: page.filter { _unreadable.contains($0.record.recordID.recordName) }.map(\.record.recordID),
                token: newToken, moreComing: moreComing)
        }
    }

    private static func integer(_ bytes: Data) -> UInt64 {
        bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// A copy as a fetch returns it: the zone owner resolved, the desired
    /// keys reordered, and unset texts and lists returned empty.
    private static func asReturned(_ subscription: CKSubscription, owner: String) -> CKSubscription {
        guard let query = subscription as? CKQuerySubscription else { return subscription }
        let copy = CKQuerySubscription(recordType: query.recordType ?? "", predicate: query.predicate,
                                       subscriptionID: query.subscriptionID, options: query.querySubscriptionOptions)
        copy.zoneID = query.zoneID.map { CKRecordZone.ID(zoneName: $0.zoneName, ownerName: owner) }
        if let info = query.notificationInfo?.copy() as? CKSubscription.NotificationInfo {
            info.desiredKeys = info.desiredKeys?.reversed()
            info.alertLocalizationArgs = info.alertLocalizationArgs ?? []
            info.subtitle = info.subtitle ?? ""
            copy.notificationInfo = info
        }
        return copy
    }
}

/// Collects the transport's log events.
final class CloudKitEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CloudKitInboxEvent] = []

    var events: [CloudKitInboxEvent] { lock.withLock { recorded } }

    var sink: @Sendable (CloudKitInboxEvent) -> Void {
        { [self] event in lock.withLock { recorded.append(event) } }
    }
}
