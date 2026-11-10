import CloudKit
import Foundation

/// The CloudKit calls the transport makes, on the signed-in account's
/// private database and its container. `CloudKitContainerService` makes
/// them for real; tests stand in for them, so no test creates a container.
/// Each call reports CloudKit's own errors (`CKError`), per item where
/// CloudKit answers per item.
public protocol CloudKitInboxService: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    /// The signed-in account's user record name.
    func userRecordName() async throws -> String

    /// Saves the zone; saving one that exists changes nothing.
    func saveZone(_ zoneID: CKRecordZone.ID) async throws
    func deleteZone(_ zoneID: CKRecordZone.ID) async throws

    /// Each requested subscription, or CloudKit's error for it
    /// (`CKError.unknownItem` when it does not exist). An ID without an
    /// entry got no answer. Throws when the request as a whole failed.
    func fetchSubscriptions(_ ids: [CKSubscription.ID]) async throws -> [CKSubscription.ID: Result<CKSubscription, Error>]
    func saveSubscription(_ subscription: CKSubscription) async throws
    func deleteSubscriptions(_ ids: [CKSubscription.ID]) async throws -> [CKSubscription.ID: Result<Void, Error>]

    /// Saves a new record without overwriting: a record with the same ID
    /// fails with `CKError.serverRecordChanged`.
    func createRecord(_ record: CKRecord) async throws
    /// Each record's deletion result; an ID without an entry got no answer.
    func deleteRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<Void, Error>]

    /// One batch of the zone's changes since `token`, or from its start when
    /// `token` is nil. An expired or unreadable token fails with
    /// `CKError.changeTokenExpired`, a missing zone with `CKError.zoneNotFound`.
    func fetchChanges(in zoneID: CKRecordZone.ID, since token: Data?) async throws -> CloudKitZoneChanges
}

/// One batch of record zone changes. Deletions are left out: the inbox only
/// cares about messages that are there.
public struct CloudKitZoneChanges: Sendable {
    /// Added or changed records, oldest first.
    public var records: [CKRecord]
    /// Records CloudKit reported as changed but failed to return.
    public var failedRecordIDs: [CKRecord.ID]
    /// The position after this batch, as opaque bytes.
    public var token: Data
    public var moreComing: Bool

    public init(records: [CKRecord], failedRecordIDs: [CKRecord.ID] = [], token: Data, moreComing: Bool = false) {
        self.records = records
        self.failedRecordIDs = failedRecordIDs
        self.token = token
        self.moreComing = moreComing
    }
}
