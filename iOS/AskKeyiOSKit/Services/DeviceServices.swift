import AskKeyDevices
import Foundation

/// Passes every call to the transport and remembers the plaintext kind of
/// each fetched record, so the app can tell which processed messages were
/// delivery checks. A processed message's plaintext kind equals its signed
/// kind; the messenger refuses any other. It fetches records by name when
/// the transport can (ADR 0014 → Polling the known records).
final class KindRecordingTransport: InboxTransport, NamedInboxFetching, @unchecked Sendable {
    let base: any InboxTransport
    private let lock = NSLock()
    private var kinds: [String: Int64] = [:]

    init(base: any InboxTransport) {
        self.base = base
    }

    /// The kinds recorded since the last call.
    func takeKinds() -> [String: Int64] {
        lock.withLock {
            defer { kinds = [:] }
            return kinds
        }
    }

    func send(_ envelope: DeviceEnvelope) async throws {
        try await base.send(envelope)
    }

    func fetchInboxChanges(of device: DeviceID, since token: InboxChangeToken?) async throws -> InboxChanges {
        let changes = try await base.fetchInboxChanges(of: device, since: token)
        lock.withLock {
            for envelope in changes.envelopes { kinds[envelope.recordName] = envelope.kind }
        }
        return changes
    }

    func deleteMessages(_ recordNames: [String], from device: DeviceID) async throws {
        try await base.deleteMessages(recordNames, from: device)
    }

    /// Throws `DeviceMessengerError.namedFetchUnavailable` when the
    /// transport cannot fetch by name.
    func fetchMessages(named recordNames: [String], from device: DeviceID) async throws -> NamedInboxFetch {
        guard let fetcher = base as? any NamedInboxFetching else { throw DeviceMessengerError.namedFetchUnavailable }
        let fetch = try await fetcher.fetchMessages(named: recordNames, from: device)
        lock.withLock {
            for envelope in fetch.envelopes { kinds[envelope.recordName] = envelope.kind }
        }
        return fetch
    }

    func accountState(storedUserRecordName: String?) async -> CloudKitAccountState {
        await base.accountState(storedUserRecordName: storedUserRecordName)
    }

    func prepareInbox() async throws -> InboxPreparation {
        try await base.prepareInbox()
    }

    func removeInbox() async throws {
        try await base.removeInbox()
    }
}

/// One identity's running services: the messenger over the transport and
/// the keychain list. The app drops it before deleting anything, so no
/// work that started earlier can write afterwards.
final class DeviceServices {
    let identity: any DeviceIdentity
    let deviceID: DeviceID
    let transport: KindRecordingTransport
    let registry: PairedDeviceRegistry
    private(set) var messenger: DeviceMessenger
    /// Grows whenever the messenger is replaced; a handler call carries the
    /// generation of the messenger that made it.
    private(set) var generation = 0
    private let clock: any DeviceClock
    private let approvalHandler: Handler?
    private let removalHook: PairedDeviceRemovalHook?

    typealias Handler = @Sendable (VerifiedApprovalMessage, _ generation: Int) async -> ApprovalMessageHandling

    /// `approvalHandler` receives verified kind 10–14 messages with the
    /// messenger's generation, and `removalHook` runs before any removal
    /// of a Mac commits.
    init(identity: any DeviceIdentity, transport: any InboxTransport, listStore: any PairedDeviceListStore,
         clock: any DeviceClock, inboxToken: InboxChangeToken?, approvalHandler: Handler? = nil,
         removalHook: PairedDeviceRemovalHook? = nil) {
        self.identity = identity
        self.clock = clock
        self.approvalHandler = approvalHandler
        self.removalHook = removalHook
        deviceID = DeviceID(messagePublicKey: identity.messagePublicKey)
        self.transport = KindRecordingTransport(base: transport)
        registry = PairedDeviceRegistry(store: listStore)
        messenger = DeviceMessenger(identity: identity, platform: .iOS, registry: registry,
                                    transport: self.transport, clock: clock, inboxToken: inboxToken,
                                    approvalHandler: Self.bind(approvalHandler, to: 0), removalHook: removalHook)
    }

    /// After an account change: the old account's token and in-memory
    /// sessions are dropped; the list is kept. Calls from the old
    /// messenger, which may still be fetching, carry the old generation.
    func restartMessenger() {
        generation += 1
        messenger = DeviceMessenger(identity: identity, platform: .iOS, registry: registry, transport: transport,
                                    clock: clock, inboxToken: nil, approvalHandler: Self.bind(approvalHandler, to: generation),
                                    removalHook: removalHook)
    }

    private static func bind(_ handler: Handler?, to generation: Int) -> ApprovalMessageHandler? {
        guard let handler else { return nil }
        return { message in await handler(message, generation) }
    }

    /// Seals approval messages with this identity and clock.
    var sealer: DeviceMessageSealer { DeviceMessageSealer(identity: identity, clock: clock) }
}
