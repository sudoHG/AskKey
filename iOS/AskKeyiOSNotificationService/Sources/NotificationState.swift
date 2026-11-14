import AskKeyDevices
import Foundation

/// What the extension may do with the shared keychain: read the identity's
/// key blobs and the paired-device list that only the app writes, and read
/// and write its own item. It has no way to write or delete anything else.
struct ExtensionKeychain: Sendable {
    /// ADR 0014 → Time-sensitive budget: in the service of the app's items
    /// (`DataProtectionKeychain.service`), the shared access group, after
    /// first unlock, this device only.
    static let stateAccount = "notification-service-state"

    private let store: any SecureItemStore

    init(store: any SecureItemStore) {
        self.store = store
    }

    /// Nil when this iPhone has no identity. Throws when the keychain cannot
    /// be read, for example before the first unlock since the phone started.
    func identityBlobs() throws -> DeviceIdentityKeyBlobs? {
        try IdentityKeychain(store: store).loadBlobs()
    }

    /// Throws when the list cannot be read or does not decode; the
    /// extension never repairs it.
    func pairedDeviceList() throws -> PairedDeviceList {
        guard let data = try store.data(for: DeviceKeychainAccount.pairedDevices) else { return PairedDeviceList() }
        return try PairedDeviceList(serialized: data)
    }

    func stateData() throws -> Data? {
        try store.data(for: Self.stateAccount)
    }

    func saveState(_ data: Data) throws {
        try store.setData(data, for: Self.stateAccount)
    }
}

/// The extension's own state, without content: when each Mac last had a
/// time-sensitive notification, and the delivery checks it answered.
struct NotificationServiceState: Codable, Equatable {
    struct DeliveryCheck: Codable, Equatable {
        var recordName: String
        var answeredAt: Date
    }

    var version = 1
    /// Mac device ID → when its last time-sensitive notification was delivered.
    var timeSensitive: [String: Date] = [:]
    var deliveryChecks: [DeliveryCheck] = []
}

/// The time-sensitive budget (ADR 0014): a detailed notification is
/// time-sensitive when no time-sensitive notification from the same Mac was
/// delivered in the preceding 120 seconds on this iPhone's clock; otherwise
/// it uses the active level.
struct NotificationStateStore: Sendable {
    static let window: TimeInterval = 120
    static let deliveryCheckLimit = 20
    /// One extension process may handle several pushes at once.
    private static let lock = NSLock()

    let keychain: ExtensionKeychain

    /// Whether this notification from `mac` may be time-sensitive; a yes is
    /// recorded before it is returned. When the item cannot be read or the
    /// time cannot be recorded, the notification uses the active level, so a
    /// broken item never lifts the budget.
    func claimTimeSensitive(for mac: DeviceID, at now: Date) -> Bool {
        Self.lock.withLock {
            guard var state = load() else { return false }
            state.timeSensitive = state.timeSensitive.filter { abs(now.timeIntervalSince($0.value)) < Self.window }
            guard state.timeSensitive[mac.text] == nil else { return false }
            state.timeSensitive[mac.text] = now
            return save(state)
        }
    }

    /// Keeps the newest answered delivery checks, by record name and time.
    func recordDeliveryCheck(_ recordName: String, at now: Date) {
        Self.lock.withLock {
            guard var state = load() else { return }
            state.deliveryChecks.append(.init(recordName: recordName, answeredAt: now))
            state.deliveryChecks = Array(state.deliveryChecks.suffix(Self.deliveryCheckLimit))
            _ = save(state)
        }
    }

    /// Nil when the keychain cannot be read; an item that does not decode
    /// is the extension's own and starts again empty.
    private func load() -> NotificationServiceState? {
        let data: Data?
        do {
            data = try keychain.stateData()
        } catch {
            return nil
        }
        guard let data else { return NotificationServiceState() }
        return (try? JSONDecoder().decode(NotificationServiceState.self, from: data)) ?? NotificationServiceState()
    }

    private func save(_ state: NotificationServiceState) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        do {
            try keychain.saveState(data)
            return true
        } catch {
            return false
        }
    }
}
