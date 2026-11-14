import CloudKit
import Foundation

/// `CloudKitInboxService` over a real container's private database. It is
/// created only from an identifier the caller passes in, never from
/// `CKContainer.default()`: creating a container terminates an app that
/// lacks the entitlement, so Debug, E2E and CI builds never create one.
final class CloudKitContainerService: CloudKitInboxService, @unchecked Sendable {
    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }

    init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    func userRecordName() async throws -> String {
        try await container.userRecordID().recordName
    }

    func zoneExists(_ zoneID: CKRecordZone.ID) async throws -> Bool {
        do {
            _ = try await database.recordZone(for: zoneID)
            return true
        } catch let error where CloudKitErrorMapping.isZoneMissing(error) || CloudKitErrorMapping.isUnknownItem(error) {
            return false
        }
    }

    func saveZone(_ zoneID: CKRecordZone.ID) async throws {
        let results = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        _ = try Self.answer(results.saveResults[zoneID]).get()
    }

    func deleteZone(_ zoneID: CKRecordZone.ID) async throws {
        let results = try await database.modifyRecordZones(saving: [], deleting: [zoneID])
        try Self.answer(results.deleteResults[zoneID]).get()
    }

    func fetchSubscriptions(_ ids: [CKSubscription.ID]) async throws -> [CKSubscription.ID: Result<CKSubscription, Error>] {
        do {
            return try await database.subscriptions(for: ids)
        } catch let error as CKError where error.code == .partialFailure {
            var results: [CKSubscription.ID: Result<CKSubscription, Error>] = [:]
            for (key, itemError) in error.partialErrorsByItemID ?? [:] {
                if let id = key as? CKSubscription.ID { results[id] = .failure(itemError) }
            }
            return results
        }
    }

    func saveSubscription(_ subscription: CKSubscription) async throws {
        let results = try await database.modifySubscriptions(saving: [subscription], deleting: [])
        _ = try Self.answer(results.saveResults[subscription.subscriptionID]).get()
    }

    func deleteSubscriptions(_ ids: [CKSubscription.ID]) async throws -> [CKSubscription.ID: Result<Void, Error>] {
        try await database.modifySubscriptions(saving: [], deleting: ids).deleteResults
    }

    func createRecord(_ record: CKRecord) async throws {
        let results = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged,
                                                       atomically: false)
        _ = try Self.answer(results.saveResults[record.recordID]).get()
    }

    func deleteRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<Void, Error>] {
        try await database.modifyRecords(saving: [], deleting: ids, savePolicy: .ifServerRecordUnchanged,
                                         atomically: false).deleteResults
    }

    func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        do {
            return try await database.configuredWith(configuration: configuration) { database in
                try await database.records(for: ids)
            }
        } catch let error as CKError where error.code == .partialFailure {
            var results: [CKRecord.ID: Result<CKRecord, Error>] = [:]
            for (key, itemError) in error.partialErrorsByItemID ?? [:] {
                if let id = key as? CKRecord.ID { results[id] = .failure(itemError) }
            }
            return results
        }
    }

    func fetchChanges(in zoneID: CKRecordZone.ID, since token: Data?) async throws -> CloudKitZoneChanges {
        var serverToken: CKServerChangeToken?
        if let token {
            guard let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token) else {
                throw CKError(.changeTokenExpired)
            }
            serverToken = decoded
        }
        let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: serverToken)
        var records: [CKRecord] = []
        var failed: [CKRecord.ID] = []
        for (recordID, result) in changes.modificationResultsByID {
            switch result {
            case .success(let modification): records.append(modification.record)
            case .failure: failed.append(recordID)
            }
        }
        records.sort { lhs, rhs in
            (lhs.creationDate ?? .distantPast, lhs.recordID.recordName) < (rhs.creationDate ?? .distantPast, rhs.recordID.recordName)
        }
        let tokenData = try NSKeyedArchiver.archivedData(withRootObject: changes.changeToken, requiringSecureCoding: true)
        return CloudKitZoneChanges(records: records, failedRecordIDs: failed, token: tokenData, moreComing: changes.moreComing)
    }

    /// A per-item result CloudKit left out counts as a failed request.
    private static func answer<T>(_ result: Result<T, Error>?) -> Result<T, Error> {
        result ?? .failure(CKError(.internalError))
    }
}
