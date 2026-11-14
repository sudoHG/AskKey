import AskKeyDevices
import Foundation
@testable import AskKeyiOSKit

/// The account's private database in memory: one inbox per device, change
/// tokens, and the account state every transport of the account sees.
final class FakeCloud: @unchecked Sendable {
    private struct Record {
        let envelope: DeviceEnvelope
        let sequence: Int
    }

    private let lock = NSLock()
    private var inboxes: [String: [String: Record]] = [:]
    private var sequence = 0
    private var sent: [DeviceEnvelope] = []
    private var sendFilter: (@Sendable (DeviceEnvelope) -> Bool)?
    private var state: CloudKitAccountState = .available(userRecordName: "_user-a")
    private var preparationError: DeviceTransportError?
    private var preparationIncomplete = false
    private(set) var preparedDevices: [DeviceID] = []
    private(set) var removedInboxes: [DeviceID] = []
    /// The record names of every fetch by name, in order.
    private(set) var namedFetches: [[String]] = []

    func transport(for device: DeviceID) -> FakeInboxTransport {
        FakeInboxTransport(cloud: self, device: device)
    }

    var accountState: CloudKitAccountState {
        get { lock.withLock { state } }
        set { lock.withLock { state = newValue } }
    }

    var prepareError: DeviceTransportError? {
        get { lock.withLock { preparationError } }
        set { lock.withLock { preparationError = newValue } }
    }

    var prepareLeavesSubscriptionsPending: Bool {
        get { lock.withLock { preparationIncomplete } }
        set { lock.withLock { preparationIncomplete = newValue } }
    }

    /// Sends for which `filter` returns true fail as if the network were down.
    func failSends(where filter: (@Sendable (DeviceEnvelope) -> Bool)?) {
        lock.withLock { sendFilter = filter }
    }

    /// Every envelope a device tried to send, in order, including failed sends.
    var sentEnvelopes: [DeviceEnvelope] { lock.withLock { sent } }

    func sent(_ kind: MessageKind, from device: DeviceID) -> [DeviceEnvelope] {
        sentEnvelopes.filter { $0.kind == Int64(kind.rawValue) && $0.sender == device.text }
    }

    func records(in device: DeviceID) -> [DeviceEnvelope] {
        lock.withLock {
            (inboxes[device.text] ?? [:]).values.sorted { $0.sequence < $1.sequence }.map(\.envelope)
        }
    }

    fileprivate func send(_ envelope: DeviceEnvelope) throws {
        try lock.withLock {
            sent.append(envelope)
            if sendFilter?(envelope) == true { throw DeviceTransportError.networkUnavailable }
            sequence += 1
            inboxes[envelope.recipient, default: [:]][envelope.recordName] = Record(envelope: envelope, sequence: sequence)
        }
    }

    fileprivate func fetch(_ device: DeviceID, since token: InboxChangeToken?) -> InboxChanges {
        lock.withLock {
            let after = token.map { Int(String(decoding: $0.data, as: UTF8.self)) ?? 0 } ?? 0
            let changed = (inboxes[device.text] ?? [:]).values.filter { $0.sequence > after }.sorted { $0.sequence < $1.sequence }
            return InboxChanges(envelopes: changed.map(\.envelope), newToken: InboxChangeToken(data: Data(String(sequence).utf8)))
        }
    }

    fileprivate func fetch(named names: [String], from device: DeviceID) -> NamedInboxFetch {
        lock.withLock {
            namedFetches.append(names)
            var fetch = NamedInboxFetch()
            for name in names {
                if let record = inboxes[device.text]?[name] {
                    fetch.envelopes.append(record.envelope)
                } else {
                    fetch.missingRecordNames.append(name)
                }
            }
            return fetch
        }
    }

    fileprivate func delete(_ names: [String], from device: DeviceID) {
        lock.withLock { for name in names { inboxes[device.text]?[name] = nil } }
    }

    fileprivate func prepare(_ device: DeviceID) throws -> InboxPreparation {
        try lock.withLock {
            if let preparationError { throw preparationError }
            preparedDevices.append(device)
            return preparationIncomplete ? InboxPreparation(pending: ["pending"]) : InboxPreparation()
        }
    }

    fileprivate func removeInbox(_ device: DeviceID) {
        lock.withLock {
            removedInboxes.append(device)
            inboxes[device.text] = nil
        }
    }
}

final class FakeInboxTransport: InboxTransport, NamedInboxFetching, @unchecked Sendable {
    let cloud: FakeCloud
    let device: DeviceID

    init(cloud: FakeCloud, device: DeviceID) {
        self.cloud = cloud
        self.device = device
    }

    func send(_ envelope: DeviceEnvelope) async throws {
        try cloud.send(envelope)
    }

    func fetchInboxChanges(of device: DeviceID, since token: InboxChangeToken?) async throws -> InboxChanges {
        cloud.fetch(device, since: token)
    }

    func deleteMessages(_ recordNames: [String], from device: DeviceID) async throws {
        cloud.delete(recordNames, from: device)
    }

    func fetchMessages(named recordNames: [String], from device: DeviceID) async throws -> NamedInboxFetch {
        cloud.fetch(named: recordNames, from: device)
    }

    func accountState(storedUserRecordName: String?) async -> CloudKitAccountState {
        let state = cloud.accountState
        if case .available(let name) = state, let storedUserRecordName, storedUserRecordName != name {
            return .accountChanged(userRecordName: name)
        }
        return state
    }

    func prepareInbox() async throws -> InboxPreparation {
        try cloud.prepare(device)
    }

    func removeInbox() async throws {
        cloud.removeInbox(device)
    }
}

/// The CloudKit gate: configured or not, and which transports were made.
final class FakeCloudFactory: InboxTransportFactory, @unchecked Sendable {
    let cloud: FakeCloud
    private let lock = NSLock()
    private var configured = true
    private var made: [DeviceID] = []
    private var continuations: [AsyncStream<Void>.Continuation] = []

    init(cloud: FakeCloud) {
        self.cloud = cloud
    }

    var isConfigured: Bool {
        get { lock.withLock { configured } }
        set { lock.withLock { configured = newValue } }
    }

    /// The devices a transport was made for, in order.
    var madeTransports: [DeviceID] { lock.withLock { made } }

    func makeTransport(for device: DeviceID) -> (any InboxTransport)? {
        lock.withLock {
            guard configured else { return nil }
            made.append(device)
            return cloud.transport(for: device)
        }
    }

    func accountChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in lock.withLock { continuations.append(continuation) } }
    }
}
