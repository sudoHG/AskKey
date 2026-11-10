import Foundation

/// The outcome of the last delivery check this device sent to a peer.
public enum DeliveryCheckResult: Hashable, Sendable {
    case pending(sentAt: Date)
    case replied(at: Date)
    /// The check's 10-minute lifetime passed without a reply.
    case noReply(sentAt: Date)

    /// The same result with its time in whole seconds, as the list stores it.
    var wholeSeconds: DeliveryCheckResult {
        switch self {
        case .pending(let date): return .pending(sentAt: UnixTime.date(UnixTime.seconds(date)))
        case .replied(let date): return .replied(at: UnixTime.date(UnixTime.seconds(date)))
        case .noReply(let date): return .noReply(sentAt: UnixTime.date(UnixTime.seconds(date)))
        }
    }
}

/// One entry of the paired-device list (ADR 0013 → Paired-device list).
public struct PairedDevice: Hashable, Sendable {
    public let card: DeviceCard
    public let pairingID: PairingID
    /// The local display name, cleaned like every display name.
    public internal(set) var displayName: String
    public let pairedAt: Date
    /// Nil until the first delivery check between the two devices succeeds.
    public internal(set) var lastReachedAt: Date?
    public internal(set) var lastDeliveryCheck: DeliveryCheckResult?

    public init(card: DeviceCard, pairingID: PairingID, displayName: String, pairedAt: Date,
                lastReachedAt: Date? = nil, lastDeliveryCheck: DeliveryCheckResult? = nil) {
        self.card = card
        self.pairingID = pairingID
        self.displayName = DeviceDisplayName.clean(displayName)
        self.pairedAt = UnixTime.date(UnixTime.seconds(pairedAt))
        self.lastReachedAt = lastReachedAt.map { UnixTime.date(UnixTime.seconds($0)) }
        self.lastDeliveryCheck = lastDeliveryCheck?.wholeSeconds
    }

    public var deviceID: DeviceID { card.deviceID }
    /// Self-declared by the peer's card; never presented as verified.
    public var platform: DevicePlatform { card.platform }
    /// False ("not reached yet") until a delivery check between the two
    /// devices succeeds, so a pairing that only one side completed shows.
    public var isReached: Bool { lastReachedAt != nil }
}

/// A list change. Every change but `add` names the pairing ID it was
/// prepared against and is dropped at commit if that entry is gone or has
/// another pairing ID, so a change prepared before a removal or a new
/// pairing cannot bring back or alter the wrong entry.
public enum PairedDeviceChange: Hashable, Sendable {
    /// Adds a device; pairing again with a device already on the list
    /// replaces its entry and pairing ID.
    case add(PairedDevice)
    case rename(DeviceID, pairingID: PairingID, displayName: String)
    case remove(DeviceID, pairingID: PairingID)
    /// The peer was reached: this device received its delivery check.
    case recordReached(DeviceID, pairingID: PairingID, at: Date)
    /// The state of the delivery check this device sent. A reply also marks
    /// the peer as reached; "no reply" applies only to the check still pending.
    case recordDeliveryCheck(DeviceID, pairingID: PairingID, result: DeliveryCheckResult)
}

public enum PairedDeviceChangeOutcome: Hashable, Sendable {
    case applied
    /// The entry the change was prepared against is gone or was replaced.
    case dropped
}

public enum PairedDeviceListError: Error, Equatable, Sendable {
    /// The list already holds 8 devices.
    case limitReached
    /// The card reuses a public key of another entry.
    case keyConflict
    /// A serialized list does not decode to a valid list.
    case malformed
}

/// A device's own list of paired devices, its only source of trust. The
/// model stores nothing; `PairedDeviceRegistry` commits changes to a store.
public struct PairedDeviceList: Hashable, Sendable {
    public static let maximumCount = 8

    public private(set) var devices: [PairedDevice]

    public init() {
        devices = []
    }

    public init(devices: [PairedDevice]) throws {
        self.init()
        for device in devices {
            guard self.device(device.deviceID) == nil else { throw PairedDeviceListError.malformed }
            _ = try apply(.add(device))
        }
    }

    public func device(_ id: DeviceID) -> PairedDevice? {
        devices.first { $0.deviceID == id }
    }

    /// Applies one change to this value.
    @discardableResult
    public mutating func apply(_ change: PairedDeviceChange) throws -> PairedDeviceChangeOutcome {
        switch change {
        case .add(let device):
            let others = devices.filter { $0.deviceID != device.deviceID }
            guard others.count < Self.maximumCount else { throw PairedDeviceListError.limitReached }
            guard others.allSatisfy({ $0.card.compressedPublicKeys.isDisjoint(with: device.card.compressedPublicKeys) }) else {
                throw PairedDeviceListError.keyConflict
            }
            if let index = devices.firstIndex(where: { $0.deviceID == device.deviceID }) {
                devices[index] = device
            } else {
                devices.append(device)
            }
            return .applied
        case .rename(let id, let pairingID, let name):
            return update(id, pairingID) { $0.displayName = DeviceDisplayName.clean(name) }
        case .remove(let id, let pairingID):
            guard let index = devices.firstIndex(where: { $0.deviceID == id && $0.pairingID == pairingID }) else {
                return .dropped
            }
            devices.remove(at: index)
            return .applied
        case .recordReached(let id, let pairingID, let date):
            return update(id, pairingID) { $0.markReached(date) }
        case .recordDeliveryCheck(let id, let pairingID, let unrounded):
            let result = unrounded.wholeSeconds
            guard let current = device(id), current.pairingID == pairingID else { return .dropped }
            if case .noReply(let sentAt) = result, current.lastDeliveryCheck != .pending(sentAt: sentAt) {
                return .dropped
            }
            return update(id, pairingID) { device in
                device.lastDeliveryCheck = result
                if case .replied(let date) = result { device.markReached(date) }
            }
        }
    }

    private mutating func update(_ id: DeviceID, _ pairingID: PairingID,
                                 _ body: (inout PairedDevice) -> Void) -> PairedDeviceChangeOutcome {
        guard let index = devices.firstIndex(where: { $0.deviceID == id && $0.pairingID == pairingID }) else {
            return .dropped
        }
        body(&devices[index])
        return .applied
    }
}

extension PairedDevice {
    mutating func markReached(_ date: Date) {
        let seconds = UnixTime.date(UnixTime.seconds(date))
        if lastReachedAt.map({ $0 < seconds }) ?? true {
            lastReachedAt = seconds
        }
    }
}

/// Where a device keeps its list. The Mac stores it in an authenticated
/// keychain item (#287), the iPhone in its data protection keychain (#289).
public protocol PairedDeviceListStore: Sendable {
    /// The stored list, or an empty list when none is stored. Throws when a
    /// stored list cannot be read or fails authentication.
    func loadPairedDeviceList() throws -> PairedDeviceList
    func savePairedDeviceList(_ list: PairedDeviceList) throws
}

/// Commits list changes as serialized read-modify-write steps: each change
/// re-reads the stored list, applies itself, and writes the result, with no
/// suspension in between. Use one registry per store.
public actor PairedDeviceRegistry {
    private let store: any PairedDeviceListStore

    public init(store: any PairedDeviceListStore) {
        self.store = store
    }

    public func list() throws -> PairedDeviceList {
        try store.loadPairedDeviceList()
    }

    @discardableResult
    public func apply(_ change: PairedDeviceChange) throws -> PairedDeviceChangeOutcome {
        var list = try store.loadPairedDeviceList()
        let outcome = try list.apply(change)
        if outcome == .applied {
            try store.savePairedDeviceList(list)
        }
        return outcome
    }
}
