import CloudKit
import Foundation

extension CloudKitDeviceTransport: NamedInboxFetching {
    /// ADR 0014 lets one named fetch ask for at most 100 records per CloudKit call.
    public static let namedFetchBatchSize = 100

    /// Fetches the named records by record ID, at most 100 per CloudKit
    /// call, with the user-initiated quality of service. Each record is
    /// handled on its own: a record that does not exist is missing, one
    /// whose fields do not form an envelope is malformed, and any other
    /// per-record error makes it failed, keeping the longest retry-after
    /// CloudKit asked for. A name that is not a message ID cannot hold a
    /// message and is reported missing without a request. When this
    /// device's own inbox zone is missing, it is created again with its
    /// subscriptions and logged, as the zone-change poll does, and its names
    /// are missing. A request that fails as a whole throws its
    /// `DeviceTransportError`; records from earlier requests of the same
    /// fetch are fetched again by the next one.
    public func fetchMessages(named recordNames: [String], from device: DeviceID) async throws -> NamedInboxFetch {
        let isOwnInbox = device == deviceID
        let zoneID = CloudKitInboxLayout.zoneID(for: device)
        var result = NamedInboxFetch()
        var seen = Set<String>()
        var names: [String] = []
        for name in recordNames where seen.insert(name).inserted {
            if MessageID(text: name) == nil {
                result.missingRecordNames.append(name)
            } else {
                names.append(name)
            }
        }
        var zoneMissing = false
        for start in stride(from: 0, to: names.count, by: Self.namedFetchBatchSize) {
            let batch = names[start..<min(start + Self.namedFetchBatchSize, names.count)]
            let ids = batch.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
            let answers: [CKRecord.ID: Result<CKRecord, Error>]
            do {
                answers = try await service.fetchRecords(ids)
            } catch let error where CloudKitErrorMapping.isZoneMissing(error) {
                zoneMissing = true
                result.missingRecordNames += batch
                continue
            } catch {
                throw CloudKitErrorMapping.transportError(for: error)
            }
            for id in ids {
                let name = id.recordName
                switch answers[id] {
                case .success(let record)?:
                    // CloudKit may return the zone's owner resolved, so only the name is compared.
                    if record.recordID.recordName == name, let envelope = CloudKitMessageRecord.envelope(from: record) {
                        result.envelopes.append(envelope)
                    } else {
                        result.malformedRecordNames.append(name)
                    }
                case .failure(let error)? where CloudKitErrorMapping.isUnknownItem(error):
                    result.missingRecordNames.append(name)
                case .failure(let error)? where CloudKitErrorMapping.isZoneMissing(error):
                    zoneMissing = true
                    result.missingRecordNames.append(name)
                case .failure(let error)?:
                    result.failedRecordNames.append(name)
                    if case DeviceTransportError.rateLimited(let retryAfter?) = CloudKitErrorMapping.transportError(for: error) {
                        result.retryAfter = max(result.retryAfter ?? retryAfter, retryAfter)
                    }
                case nil:
                    result.failedRecordNames.append(name)
                }
            }
        }
        if zoneMissing, isOwnInbox {
            try await recreateOwnZone()
        }
        return result
    }
}
