import Foundation

/// A versioned serialization of the list for the stores in #287 and #289.
/// Decoding re-verifies every card and refuses anything that is not a valid
/// list; it never repairs one.
extension PairedDeviceList {
    public static let serializationVersion = 1

    private struct Document: Codable {
        let version: Int
        let devices: [Entry]
    }

    private struct Entry: Codable {
        let card: Data
        let pairingID: Data
        let displayName: String
        let pairedAt: Int64
        let lastReachedAt: Int64?
        let lastDeliveryCheck: Check?
    }

    private struct Check: Codable {
        let state: String
        let time: Int64
    }

    public func serialized() throws -> Data {
        let entries = devices.map { device in
            Entry(card: device.card.bytes, pairingID: device.pairingID.rawValue, displayName: device.displayName,
                  pairedAt: UnixTime.seconds(device.pairedAt), lastReachedAt: device.lastReachedAt.map(UnixTime.seconds),
                  lastDeliveryCheck: device.lastDeliveryCheck.map(Self.encode))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Document(version: Self.serializationVersion, devices: entries))
    }

    public init(serialized data: Data) throws {
        guard let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == Self.serializationVersion,
              document.devices.count <= Self.maximumCount else {
            throw PairedDeviceListError.malformed
        }
        var devices: [PairedDevice] = []
        for entry in document.devices {
            guard let card = try? DeviceCard(bytes: entry.card),
                  let pairingID = PairingID(rawValue: entry.pairingID),
                  entry.displayName == DeviceDisplayName.clean(entry.displayName),
                  entry.pairedAt >= 0, (entry.lastReachedAt ?? 0) >= 0 else {
                throw PairedDeviceListError.malformed
            }
            let check = try entry.lastDeliveryCheck.map(Self.decode)
            devices.append(PairedDevice(card: card, pairingID: pairingID, displayName: entry.displayName,
                                        pairedAt: UnixTime.date(entry.pairedAt),
                                        lastReachedAt: entry.lastReachedAt.map(UnixTime.date),
                                        lastDeliveryCheck: check))
        }
        do {
            try self.init(devices: devices)
        } catch {
            throw PairedDeviceListError.malformed
        }
    }

    private static func encode(_ result: DeliveryCheckResult) -> Check {
        switch result {
        case .pending(let date): return Check(state: "pending", time: UnixTime.seconds(date))
        case .replied(let date): return Check(state: "replied", time: UnixTime.seconds(date))
        case .noReply(let date): return Check(state: "noReply", time: UnixTime.seconds(date))
        }
    }

    private static func decode(_ check: Check) throws -> DeliveryCheckResult {
        guard check.time >= 0 else { throw PairedDeviceListError.malformed }
        let date = UnixTime.date(check.time)
        switch check.state {
        case "pending": return .pending(sentAt: date)
        case "replied": return .replied(at: date)
        case "noReply": return .noReply(sentAt: date)
        default: throw PairedDeviceListError.malformed
        }
    }
}
