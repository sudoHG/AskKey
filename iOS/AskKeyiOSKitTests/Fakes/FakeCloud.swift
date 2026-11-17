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
    private var hook: (@Sendable (DeviceEnvelope) async -> Void)?
    private var fetchesFail = false
    private var namedError: DeviceTransportError?
    private var namedRetryAfter: TimeInterval?
    private var recordRetryAfter: TimeInterval?
    private var state: CloudKitAccountState = .available(userRecordName: "_user-a")
    private var preparationError: DeviceTransportError?
    private var preparationIncomplete = false
    private(set) var preparedDevices: [DeviceID] = []
    private(set) var removedInboxes: [DeviceID] = []
    /// The record names of every fetch by name, in order.
    private(set) var namedFetches: [[String]] = []
    private var log: [Call] = []
    private var callObserver: (@Sendable (Call) async -> Void)?

    /// One transport call, by the device whose transport made it.
    struct Call: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case accountState
            case prepareInbox
            case zoneFetch
            case namedFetch([String])
            case delete([String])
            case send(Int64)
        }

        let device: String
        let kind: Kind
    }

    /// Every transport call, in order, before it took effect.
    var calls: [Call] { lock.withLock { log } }

    /// The calls one device's transport made, in order.
    func calls(by device: DeviceID) -> [Call.Kind] {
        calls.filter { $0.device == device.text }.map(\.kind)
    }

    func clearCalls() {
        lock.withLock { log = [] }
    }

    /// Runs before every transport call takes effect, while the caller waits for it.
    var callHook: (@Sendable (Call) async -> Void)? {
        get { lock.withLock { callObserver } }
        set { lock.withLock { callObserver = newValue } }
    }

    fileprivate func record(_ kind: Call.Kind, by device: DeviceID) async {
        let call = Call(device: device.text, kind: kind)
        let hook = lock.withLock {
            log.append(call)
            return callObserver
        }
        await hook?(call)
    }

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

    /// Runs before every send, while the sender waits for it.
    var sendHook: (@Sendable (DeviceEnvelope) async -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    /// Zone-change fetches fail as if the network were down; fetches by name work.
    var zoneFetchesFail: Bool {
        get { lock.withLock { fetchesFail } }
        set { lock.withLock { fetchesFail = newValue } }
    }

    /// Fetches by name throw this, as a call that fails as a whole would.
    var namedFetchError: DeviceTransportError? {
        get { lock.withLock { namedError } }
        set { lock.withLock { namedError = newValue } }
    }

    /// Fetches by name answer with this retry-after, as CloudKit asking to wait.
    var namedFetchRetryAfter: TimeInterval? {
        get { lock.withLock { namedRetryAfter } }
        set { lock.withLock { namedRetryAfter = newValue } }
    }

    /// Fetches by name report each record failed with this retry-after, as
    /// CloudKit's per-record rate limit does.
    var namedRecordsRetryAfter: TimeInterval? {
        get { lock.withLock { recordRetryAfter } }
        set { lock.withLock { recordRetryAfter = newValue } }
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

    fileprivate func fetch(_ device: DeviceID, since token: InboxChangeToken?) throws -> InboxChanges {
        try lock.withLock {
            if fetchesFail { throw DeviceTransportError.networkUnavailable }
            let after = token.map { Int(String(decoding: $0.data, as: UTF8.self)) ?? 0 } ?? 0
            let changed = (inboxes[device.text] ?? [:]).values.filter { $0.sequence > after }.sorted { $0.sequence < $1.sequence }
            return InboxChanges(envelopes: changed.map(\.envelope), newToken: InboxChangeToken(data: Data(String(sequence).utf8)))
        }
    }

    fileprivate func fetch(named names: [String], from device: DeviceID) throws -> NamedInboxFetch {
        try lock.withLock {
            namedFetches.append(names)
            if let namedError { throw namedError }
            if let recordRetryAfter { return NamedInboxFetch(failedRecordNames: names, retryAfter: recordRetryAfter) }
            var fetch = NamedInboxFetch(retryAfter: namedRetryAfter)
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
        await cloud.record(.send(envelope.kind), by: device)
        await cloud.sendHook?(envelope)
        try cloud.send(envelope)
    }

    func fetchInboxChanges(of device: DeviceID, since token: InboxChangeToken?) async throws -> InboxChanges {
        await cloud.record(.zoneFetch, by: self.device)
        return try cloud.fetch(device, since: token)
    }

    func deleteMessages(_ recordNames: [String], from device: DeviceID) async throws {
        await cloud.record(.delete(recordNames), by: self.device)
        cloud.delete(recordNames, from: device)
    }

    func fetchMessages(named recordNames: [String], from device: DeviceID) async throws -> NamedInboxFetch {
        await cloud.record(.namedFetch(recordNames), by: self.device)
        return try cloud.fetch(named: recordNames, from: device)
    }

    func accountState(storedUserRecordName: String?) async -> CloudKitAccountState {
        await cloud.record(.accountState, by: device)
        let state = cloud.accountState
        if case .available(let name) = state, let storedUserRecordName, storedUserRecordName != name {
            return .accountChanged(userRecordName: name)
        }
        return state
    }

    func prepareInbox() async throws -> InboxPreparation {
        await cloud.record(.prepareInbox, by: device)
        return try cloud.prepare(device)
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
