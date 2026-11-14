import CloudKit
import Foundation

extension CloudKitDeviceTransport: NamedInboxFetching {
    /// ADR 0014 lets one named fetch ask for at most 100 records per CloudKit call.
    public static let namedFetchBatchSize = 100

    /// `fetchMessages(named:from:recreatingMissingZone:)` with a missing own
    /// inbox zone created again, as the zone-change poll does.
    public func fetchMessages(named recordNames: [String], from device: DeviceID) async throws -> NamedInboxFetch {
        try await fetchMessages(named: recordNames, from: device, recreatingMissingZone: true)
    }

    /// Fetches the named records by record ID, at most 100 per CloudKit
    /// call, with the user-initiated quality of service. Each record is
    /// handled on its own: a record that does not exist is missing, one
    /// whose fields do not form an envelope is malformed, and any other
    /// per-record error makes it failed, keeping the longest retry-after
    /// CloudKit asked for. Once CloudKit asks to wait, or a later call fails
    /// as a whole, no further call is made: the names not yet answered are
    /// reported failed, with the retry-after, and the records already
    /// fetched are returned. A first call that fails as a whole throws its
    /// `DeviceTransportError`. A name that is not a message ID cannot hold a
    /// message and is reported missing without a request.
    ///
    /// When this device's own inbox zone is missing, its names are missing;
    /// with `recreatingMissingZone` the zone is created again with its
    /// subscriptions and logged, as the zone-change poll does. Pass false
    /// from a process that must not repair the inbox, such as the
    /// notification extension.
    public func fetchMessages(named recordNames: [String], from device: DeviceID,
                              recreatingMissingZone: Bool) async throws -> NamedInboxFetch {
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
            let end = min(start + Self.namedFetchBatchSize, names.count)
            let batch = names[start..<end]
            let answers: [CKRecord.ID: Result<CKRecord, Error>]
            do {
                answers = try await service.fetchRecords(batch.map { CKRecord.ID(recordName: $0, zoneID: zoneID) })
            } catch let error where CloudKitErrorMapping.isZoneMissing(error) {
                zoneMissing = true
                result.missingRecordNames += batch
                continue
            } catch {
                let mapped = CloudKitErrorMapping.transportError(for: error)
                guard start > 0 else { throw mapped }
                result.failedRecordNames += names[start...]
                result.keepLongestRetryAfter(from: mapped)
                break
            }
            // Matched by name: CloudKit may return the zone's owner resolved.
            var byName: [String: Result<CKRecord, Error>] = [:]
            for (id, answer) in answers where byName[id.recordName] == nil {
                byName[id.recordName] = answer
            }
            for name in batch {
                switch byName[name] {
                case .success(let record)?:
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
                    result.keepLongestRetryAfter(from: CloudKitErrorMapping.transportError(for: error))
                case nil:
                    result.failedRecordNames.append(name)
                }
            }
            if result.retryAfter != nil {
                result.failedRecordNames += names[end...]
                break
            }
        }
        if zoneMissing, device == deviceID, recreatingMissingZone {
            try await recreateOwnZone()
        }
        return result
    }
}

private extension NamedInboxFetch {
    mutating func keepLongestRetryAfter(from error: Error) {
        if case DeviceTransportError.rateLimited(let wait?) = error {
            retryAfter = max(retryAfter ?? wait, wait)
        }
    }
}
