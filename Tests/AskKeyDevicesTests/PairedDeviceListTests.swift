import AskKeyDevices
import AskKeyDevicesTestSupport
import CryptoKit
import XCTest

final class PairedDeviceListTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ identity: SoftwareDeviceIdentity = SoftwareDeviceIdentity(), name: String = "Phone",
                       pairing: UInt8 = 1) throws -> PairedDevice {
        let card = try DeviceCard.make(identity: identity, platform: .iOS, createdAt: now)
        return PairedDevice(card: card, pairingID: PairingID(rawValue: Data(repeating: pairing, count: 16))!,
                            displayName: name, pairedAt: now)
    }

    func testLimitOfEightAndPairingAgainReplacesTheEntry() throws {
        var list = PairedDeviceList()
        let first = SoftwareDeviceIdentity()
        try list.apply(.add(try entry(first)))
        for _ in 1..<8 { try list.apply(.add(try entry())) }
        XCTAssertEqual(list.devices.count, PairedDeviceList.maximumCount)
        XCTAssertThrowsError(try list.apply(.add(try entry()))) {
            XCTAssertEqual($0 as? PairedDeviceListError, .limitReached)
        }
        let replacement = try entry(first, name: "Phone again", pairing: 2)
        XCTAssertEqual(try list.apply(.add(replacement)), .applied, "pairing again replaces, even when full")
        XCTAssertEqual(list.devices.count, 8)
        XCTAssertEqual(list.device(replacement.deviceID)?.pairingID, replacement.pairingID)
        XCTAssertFalse(list.device(replacement.deviceID)!.isReached)
    }

    func testCardSharingAKeyWithAnotherEntryIsRefused() throws {
        let sharedKey = P256.Signing.PrivateKey()
        let shared = SoftwareDeviceIdentity(messageKey: sharedKey, agreementKey: .init(), approvalKey: .init())
        var list = try PairedDeviceList(devices: [try entry(shared)])
        // A device whose approval key is another entry's message key.
        let copy = SoftwareDeviceIdentity(messageKey: .init(), agreementKey: .init(), approvalKey: sharedKey)
        XCTAssertThrowsError(try list.apply(.add(try entry(copy)))) {
            XCTAssertEqual($0 as? PairedDeviceListError, .keyConflict)
        }
    }

    func testChangesPreparedAgainstAnotherPairingAreDropped() throws {
        let identity = SoftwareDeviceIdentity()
        var list = try PairedDeviceList(devices: [try entry(identity, pairing: 1)])
        let id = list.devices[0].deviceID
        let stale = PairingID(rawValue: Data(repeating: 9, count: 16))!
        let current = list.devices[0].pairingID
        XCTAssertEqual(try list.apply(.rename(id, pairingID: stale, displayName: "X")), .dropped)
        XCTAssertEqual(try list.apply(.remove(id, pairingID: stale)), .dropped)
        XCTAssertEqual(try list.apply(.recordReached(id, pairingID: stale, at: now)), .dropped)
        XCTAssertEqual(list.devices.count, 1)

        let sent = now.addingTimeInterval(10)
        XCTAssertEqual(try list.apply(.recordDeliveryCheck(id, pairingID: current, result: .pending(sentAt: sent))), .applied)
        XCTAssertEqual(try list.apply(.recordDeliveryCheck(id, pairingID: current, result: .noReply(sentAt: now))), .dropped,
                       "no reply applies only to the check still pending")
        XCTAssertEqual(try list.apply(.recordDeliveryCheck(id, pairingID: current, result: .replied(at: sent.addingTimeInterval(1)))), .applied)
        XCTAssertEqual(try list.apply(.recordDeliveryCheck(id, pairingID: current, result: .noReply(sentAt: sent))), .dropped)
        XCTAssertEqual(list.devices[0].lastReachedAt, sent.addingTimeInterval(1))
        XCTAssertEqual(try list.apply(.rename(id, pairingID: current, displayName: "\u{2066}Desk\u{2069} Phone\u{0007}")), .applied)
        XCTAssertEqual(list.devices[0].displayName, "Desk Phone")
        XCTAssertEqual(try list.apply(.remove(id, pairingID: current)), .applied)
        XCTAssertTrue(list.devices.isEmpty)
    }

    func testSerializationRoundTripsAndRefusesDamagedLists() throws {
        var list = try PairedDeviceList(devices: [try entry(name: "One"), try entry(name: "Two", pairing: 2)])
        try list.apply(.recordDeliveryCheck(list.devices[1].deviceID, pairingID: list.devices[1].pairingID,
                                            result: .replied(at: now.addingTimeInterval(5))))
        let data = try list.serialized()
        XCTAssertEqual(try PairedDeviceList(serialized: data), list)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let damaged: [(String, ([String: Any]) -> [String: Any])] = [
            ("newer version", { var j = $0; j["version"] = 3; return j }),
            ("damaged card", { j in
                var j = j
                var devices = j["devices"] as! [[String: Any]]
                var card = Data(base64Encoded: devices[0]["card"] as! String)!
                card[20] ^= 1
                devices[0]["card"] = card.base64EncodedString()
                j["devices"] = devices
                return j
            }),
            ("duplicate device", { var j = $0; let d = j["devices"] as! [[String: Any]]; j["devices"] = [d[0], d[0]]; return j }),
            ("unclean name", { var j = $0; var d = j["devices"] as! [[String: Any]]; d[0]["displayName"] = "Bad\u{202E}"; j["devices"] = d; return j }),
            ("short pairing ID", { var j = $0; var d = j["devices"] as! [[String: Any]]; d[0]["pairingID"] = "AAAA"; j["devices"] = d; return j }),
            ("unknown check state", { var j = $0; var d = j["devices"] as! [[String: Any]]; d[1]["lastDeliveryCheck"] = ["state": "maybe", "time": 1]; j["devices"] = d; return j }),
        ]
        for (name, change) in damaged {
            let bytes = try JSONSerialization.data(withJSONObject: change(json))
            XCTAssertThrowsError(try PairedDeviceList(serialized: bytes), name) {
                XCTAssertEqual($0 as? PairedDeviceListError, .malformed, name)
            }
        }
        json["devices"] = Array(repeating: (json["devices"] as! [[String: Any]])[0], count: 9)
        XCTAssertThrowsError(try PairedDeviceList(serialized: try JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try PairedDeviceList(serialized: Data("not json".utf8)))
    }

    func testRegistryCommitsEachChangeAgainstTheStoredList() async throws {
        let store = InMemoryPairedDeviceListStore()
        let registry = PairedDeviceRegistry(store: store)
        let device = try entry()
        try await registry.apply(.add(device))
        XCTAssertNotNil(store.storedBytes)
        store.failNextSaves(1)
        do {
            try await registry.apply(.rename(device.deviceID, pairingID: device.pairingID, displayName: "Lost"))
            XCTFail("a failed save throws")
        } catch {}
        await XCTAssertEqualAsync(try await registry.list().devices.first?.displayName, "Phone", "a failed save changes nothing")
        // A second registry over the same store sees every committed change.
        let other = PairedDeviceRegistry(store: store)
        try await other.apply(.remove(device.deviceID, pairingID: device.pairingID))
        await XCTAssertEqualAsync(try await registry.apply(.recordReached(device.deviceID, pairingID: device.pairingID, at: now)), .dropped)
    }
}
