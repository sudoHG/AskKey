import AskKeyDevices
import Foundation
@testable import AskKeyiOSKit

final class InMemoryKeychain: SecureItemStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var failWrites = false

    var accounts: Set<String> { lock.withLock { Set(items.keys) } }

    var writesFail: Bool {
        get { lock.withLock { failWrites } }
        set { lock.withLock { failWrites = newValue } }
    }

    func data(for account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    func setData(_ data: Data, for account: String) throws {
        try lock.withLock {
            if failWrites { throw KeychainError(status: errSecIO) }
            items[account] = data
        }
    }

    func deleteData(for account: String) throws {
        lock.withLock { items[account] = nil }
    }
}

final class InMemoryLocalState: LocalStateStore {
    var inboxPosition: InboxPosition?
    var deviceID: String?
    var deliveryRecords: [DeliveryRecord] = []

    func removeAll() {
        inboxPosition = nil
        deviceID = nil
        deliveryRecords = []
    }
}

final class FakeBiometry: BiometryChecking, @unchecked Sendable {
    var current: BiometryStatus = .enrolled(.faceID)

    func status() -> BiometryStatus { current }
}

final class FakeCamera: CameraAccessChecking, @unchecked Sendable {
    var current: CameraAccess = .unavailable
    var grantsAccess = true

    func access() -> CameraAccess { current }

    func requestAccess() async -> Bool {
        current = grantsAccess ? .authorized : .denied
        return grantsAccess
    }
}

final class FakeNotifications: NotificationCenterAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var hints: [PushHint] = []
    private var removed: [String] = []
    private var requests = 0

    var authorizationRequests: Int { lock.withLock { requests } }
    var removedIdentifiers: [String] { lock.withLock { removed } }

    /// The pushes Notification Center holds for this device.
    var delivered: [PushHint] {
        get { lock.withLock { hints } }
        set { lock.withLock { hints = newValue } }
    }

    func requestAuthorizationAndRegister() async {
        lock.withLock { requests += 1 }
    }

    func registerAtLaunch() async {}

    func deliveredPushHints(for device: DeviceID) async -> [PushHint] {
        delivered
    }

    func removeDeliveredNotifications(identifiers: [String]) {
        lock.withLock {
            removed += identifiers
            hints.removeAll { $0.notificationIdentifier.map(identifiers.contains) ?? false }
        }
    }
}

final class ManualClock: DeviceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date { lock.withLock { current } }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}

/// A list store in memory, through the list's serialization like the keychain store.
final class InMemoryListStore: PairedDeviceListStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    func loadPairedDeviceList() throws -> PairedDeviceList {
        guard let data = lock.withLock({ stored }) else { return PairedDeviceList() }
        return try PairedDeviceList(serialized: data)
    }

    func savePairedDeviceList(_ list: PairedDeviceList) throws {
        let data = try list.serialized()
        lock.withLock { stored = data }
    }
}
