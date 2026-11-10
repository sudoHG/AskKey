import AskKeyDevices
import Foundation

/// Passes every call to the transport and remembers the plaintext kind of
/// each fetched record, so the app can tell which processed messages were
/// delivery checks. A processed message's plaintext kind equals its signed
/// kind; the messenger refuses any other.
final class KindRecordingTransport: InboxTransport, @unchecked Sendable {
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
    private let clock: any DeviceClock

    init(identity: any DeviceIdentity, transport: any InboxTransport, listStore: any PairedDeviceListStore,
         clock: any DeviceClock, inboxToken: InboxChangeToken?) {
        self.identity = identity
        self.clock = clock
        deviceID = DeviceID(messagePublicKey: identity.messagePublicKey)
        self.transport = KindRecordingTransport(base: transport)
        registry = PairedDeviceRegistry(store: listStore)
        messenger = DeviceMessenger(identity: identity, platform: .iOS, registry: registry,
                                    transport: self.transport, clock: clock, inboxToken: inboxToken)
    }

    /// After an account change: the old account's token and in-memory
    /// sessions are dropped; the list is kept.
    func restartMessenger() {
        messenger = DeviceMessenger(identity: identity, platform: .iOS, registry: registry, transport: transport,
                                    clock: clock, inboxToken: nil)
    }
}
