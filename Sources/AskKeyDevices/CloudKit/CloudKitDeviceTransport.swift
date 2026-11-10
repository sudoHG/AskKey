import CloudKit
import Foundation

/// What one inbox preparation did.
public struct InboxPreparation: Hashable, Sendable {
    /// Subscriptions saved by this preparation, because CloudKit answered
    /// that they do not exist or because their definition had been replaced.
    public var saved: [CKSubscription.ID] = []
    /// Subscriptions whose fetch answered with another error, or whose save
    /// failed. Nothing was saved on such an answer; a later preparation
    /// fetches them again.
    public var pending: [CKSubscription.ID] = []

    public var isComplete: Bool { pending.isEmpty }

    public init(saved: [CKSubscription.ID] = [], pending: [CKSubscription.ID] = []) {
        self.saved = saved
        self.pending = pending
    }
}

/// `DeviceTransport` over the signed-in account's CloudKit private database,
/// following ADR 0013 → CloudKit layout. One transport belongs to one device:
/// it creates only that device's inbox zone and subscriptions, writes sends
/// into other devices' existing inboxes, and leaves the change token, the
/// processed message IDs and every message decision to `DeviceMessenger`.
///
/// Nothing here retries a send. Expired messages are returned like any
/// other, and the messenger refuses them (`DeviceMessageRefusal.expired`)
/// and deletes them in the same poll.
public actor CloudKitDeviceTransport: DeviceTransport {
    /// After a preparation left something undone, a fetch of the own inbox
    /// prepares again at most this often (longer when CloudKit asks for it).
    public static let preparationRetryInterval: TimeInterval = 60
    /// CloudKit takes at most 400 items in one modify request.
    static let deletionBatchSize = 400

    public nonisolated let deviceID: DeviceID
    public nonisolated let platform: DevicePlatform
    nonisolated let service: any CloudKitInboxService
    nonisolated let clock: any DeviceClock
    nonisolated let log: @Sendable (CloudKitInboxEvent) -> Void

    private var inboxReady = false
    private var nextPreparation: Date?
    private var runningPreparation: Task<InboxPreparation, Error>?

    /// A transport on the private database of the container `containerIdentifier`.
    /// Create it only in a build whose signed entitlements contain that
    /// container: creating a container without them terminates the app.
    public init(containerIdentifier: String, deviceID: DeviceID, platform: DevicePlatform,
                clock: any DeviceClock = SystemDeviceClock(),
                log: @escaping @Sendable (CloudKitInboxEvent) -> Void = CloudKitInboxEvent.systemLog) {
        self.init(service: CloudKitContainerService(containerIdentifier: containerIdentifier), deviceID: deviceID,
                  platform: platform, clock: clock, log: log)
    }

    public init(service: any CloudKitInboxService, deviceID: DeviceID, platform: DevicePlatform,
                clock: any DeviceClock = SystemDeviceClock(),
                log: @escaping @Sendable (CloudKitInboxEvent) -> Void = CloudKitInboxEvent.systemLog) {
        self.service = service
        self.deviceID = deviceID
        self.platform = platform
        self.clock = clock
        self.log = log
    }

    private var ownZoneID: CKRecordZone.ID { CloudKitInboxLayout.zoneID(for: deviceID) }

    // MARK: Inbox and subscriptions

    /// Creates this device's inbox zone (saving an existing zone changes
    /// nothing) and makes sure its two subscriptions are the ones ADR 0013
    /// defines, without saving a matching subscription again: re-saving one
    /// loses about a minute of pushes (#281). It fetches the subscriptions by
    /// ID; only a "does not exist" answer leads to a save. A fetched
    /// subscription whose definition differs was replaced by someone else and
    /// is saved correctly once. Any other answer saves nothing and leaves the
    /// subscription pending for a later preparation. Each save is logged
    /// with its subscription ID and time. Once a preparation completes, later
    /// calls in this process return at once. Throws `DeviceTransportError`
    /// when the zone save or the subscription fetch as a whole fails.
    public func prepareInbox() async throws -> InboxPreparation {
        guard !inboxReady else { return InboxPreparation() }
        return try await prepare()
    }

    /// Deletes this device's inbox zone and both subscriptions, for resetting
    /// an unusable identity (ADR 0013 → Removal and account changes); items
    /// that are already gone count as deleted. Discard the transport
    /// afterwards: a later fetch would create the inbox again.
    public func removeInbox() async throws {
        inboxReady = false
        let ids = MessageRecordType.allCases.map { CloudKitInboxLayout.subscriptionID(for: deviceID, recordType: $0) }
        do {
            let results = try await service.deleteSubscriptions(ids)
            for id in ids {
                if case .failure(let error)? = results[id], !CloudKitErrorMapping.isUnknownItem(error) { throw error }
            }
            try await service.deleteZone(ownZoneID)
        } catch let error where CloudKitErrorMapping.isZoneMissing(error) {
            return
        } catch {
            throw CloudKitErrorMapping.transportError(for: error)
        }
    }

    /// Runs one preparation, or joins the one already running, so two
    /// callers never save the same subscription twice.
    private func prepare() async throws -> InboxPreparation {
        if let runningPreparation { return try await runningPreparation.value }
        let task = Task { try await self.runPreparation() }
        runningPreparation = task
        defer { runningPreparation = nil }
        return try await task.value
    }

    private func runPreparation() async throws -> InboxPreparation {
        nextPreparation = clock.now().addingTimeInterval(Self.preparationRetryInterval)
        do {
            try await service.saveZone(ownZoneID)
        } catch {
            throw failure(error)
        }
        let expected = CloudKitInboxLayout.subscriptions(for: deviceID, platform: platform)
        let fetched: [CKSubscription.ID: Result<CKSubscription, Error>]
        do {
            fetched = try await service.fetchSubscriptions(expected.map(\.subscriptionID))
        } catch {
            throw failure(error)
        }
        var report = InboxPreparation()
        for subscription in expected {
            let id = subscription.subscriptionID
            let replaced: Bool
            switch fetched[id] {
            case .success(let existing):
                guard !CloudKitSubscriptionDefinition.matches(existing, subscription) else { continue }
                replaced = true
            case .failure(let error) where CloudKitErrorMapping.isUnknownItem(error):
                replaced = false
            case .failure, nil:
                report.pending.append(id)
                continue
            }
            do {
                try await service.saveSubscription(subscription)
            } catch {
                _ = failure(error)
                report.pending.append(id)
                continue
            }
            report.saved.append(id)
            let now = clock.now()
            log(replaced ? .subscriptionRepaired(subscriptionID: id, at: now) : .subscriptionSaved(subscriptionID: id, at: now))
        }
        inboxReady = report.isComplete
        return report
    }

    /// Maps a preparation error and pushes the next automatic attempt back
    /// when CloudKit asks to wait longer than the usual interval.
    private func failure(_ error: Error) -> Error {
        let mapped = CloudKitErrorMapping.transportError(for: error)
        if case DeviceTransportError.rateLimited(let retryAfter?) = mapped, retryAfter > Self.preparationRetryInterval {
            nextPreparation = clock.now().addingTimeInterval(retryAfter)
        }
        return mapped
    }

    /// Finishes a preparation that an earlier attempt left undone, if one is due.
    private func prepareIfDue() async {
        guard !inboxReady else { return }
        if let nextPreparation, clock.now() < nextPreparation { return }
        _ = try? await prepare()
    }

    // MARK: DeviceTransport

    /// Writes the envelope into the recipient's existing inbox zone; this
    /// device never creates another device's zone. A missing zone means the
    /// recipient is unreachable. A record that already exists under the
    /// message ID counts as sent, because the caller resends a message with
    /// the same ID after a save whose outcome it could not see.
    public func send(_ envelope: DeviceEnvelope) async throws {
        let record: CKRecord
        do {
            record = try CloudKitMessageRecord.record(for: envelope)
        } catch CloudKitMessageRecord.EncodingError.invalidRecipient {
            throw DeviceTransportError.recipientUnreachable
        }
        do {
            try await service.createRecord(record)
        } catch let error where CloudKitErrorMapping.cloudKitError(error)?.code == .serverRecordChanged {
            return
        } catch {
            throw CloudKitErrorMapping.transportError(for: error)
        }
    }

    /// One batch of the inbox's changes. For this device's own inbox it
    /// first finishes a due preparation, and when the zone is missing it
    /// creates the zone and its subscriptions again, logs it, and returns the
    /// new zone's changes from no token. Records that do not map to an
    /// envelope are reported as malformed, and records CloudKit failed to
    /// return as failed, so the messenger keeps the token behind them.
    public func fetchInboxChanges(of device: DeviceID, since token: InboxChangeToken?) async throws -> InboxChanges {
        let isOwnInbox = device == deviceID
        if isOwnInbox { await prepareIfDue() }
        let zoneID = CloudKitInboxLayout.zoneID(for: device)
        let changes: CloudKitZoneChanges
        do {
            changes = try await service.fetchChanges(in: zoneID, since: token?.data)
        } catch let error where isOwnInbox && CloudKitErrorMapping.isZoneMissing(error) {
            try await recreateOwnZone()
            do {
                changes = try await service.fetchChanges(in: zoneID, since: nil)
            } catch {
                throw CloudKitErrorMapping.transportError(for: error)
            }
        } catch {
            throw CloudKitErrorMapping.transportError(for: error)
        }
        var envelopes: [DeviceEnvelope] = []
        var malformed: [String] = []
        for record in changes.records {
            if let envelope = CloudKitMessageRecord.envelope(from: record) {
                envelopes.append(envelope)
            } else {
                malformed.append(record.recordID.recordName)
            }
        }
        return InboxChanges(envelopes: envelopes, malformedRecordNames: malformed,
                            failedRecordNames: changes.failedRecordIDs.map(\.recordName),
                            newToken: InboxChangeToken(data: changes.token), moreComing: changes.moreComing)
    }

    /// Deletes records from the inbox in batches. A record or zone that is
    /// already gone counts as deleted; any other failure is thrown after
    /// every batch was tried, so the messenger keeps its token and the next
    /// poll deletes the rest.
    public func deleteMessages(_ recordNames: [String], from device: DeviceID) async throws {
        let zoneID = CloudKitInboxLayout.zoneID(for: device)
        let ids = recordNames.filter { !$0.isEmpty }.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        var firstFailure: Error?
        for start in stride(from: 0, to: ids.count, by: Self.deletionBatchSize) {
            let batch = Array(ids[start..<min(start + Self.deletionBatchSize, ids.count)])
            do {
                let results = try await service.deleteRecords(batch)
                for id in batch {
                    switch results[id] {
                    case .success?:
                        continue
                    case .failure(let error)? where CloudKitErrorMapping.isUnknownItem(error)
                        || CloudKitErrorMapping.isZoneMissing(error):
                        continue
                    case .failure(let error)?:
                        firstFailure = firstFailure ?? error
                    case nil:
                        firstFailure = firstFailure ?? CKError(.internalError)
                    }
                }
            } catch let error where CloudKitErrorMapping.isZoneMissing(error) {
                continue
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw CloudKitErrorMapping.transportError(for: firstFailure) }
    }

    /// Someone deleted this device's inbox zone: create it again, log it,
    /// and check the subscriptions as a preparation would.
    private func recreateOwnZone() async throws {
        inboxReady = false
        do {
            try await service.saveZone(ownZoneID)
        } catch {
            throw CloudKitErrorMapping.transportError(for: error)
        }
        log(.inboxZoneRecreated(at: clock.now()))
        _ = try? await prepare()
    }
}
