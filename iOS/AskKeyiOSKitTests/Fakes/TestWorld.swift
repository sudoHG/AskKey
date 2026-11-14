import AskKeyDevices
import Foundation
import XCTest
@testable import AskKeyiOSKit

/// A Mac played by a real `DeviceMessenger` on the same in-memory account.
struct MacPeer {
    let identity: SoftwareIdentity
    let messenger: DeviceMessenger
    let name: String

    var deviceID: DeviceID { identity.deviceID }
}

/// One iPhone app with fakes for keys, keychain and transport, and Macs
/// played by real `DeviceMessenger`s on the same in-memory account, on
/// their own clock (`macClock`, which can run fast or slow).
@MainActor
final class TestWorld {
    let clock = ManualClock()
    let cloud = FakeCloud()
    let factory: FakeCloudFactory
    let keychain = InMemoryKeychain()
    let localState = InMemoryLocalState()
    let identities = FakeIdentityFactory()
    let biometry = FakeBiometry()
    let camera = FakeCamera()
    let notifications = FakeNotifications()
    let approvalStore = InMemoryApprovalStore()
    let macClock: OffsetClock
    /// What every Mac's messenger verified: decisions, receipts, confirmations.
    let macInbox = MacInbox()
    private(set) lazy var model = AppModel(environment: environment)

    let macIdentity = SoftwareIdentity()
    private(set) lazy var mac = makeMessenger(for: macIdentity)
    static let macName = "Studio Mac"

    init() {
        factory = FakeCloudFactory(cloud: cloud)
        macClock = OffsetClock(base: clock)
    }

    var environment: AppEnvironment {
        AppEnvironment(identities: identities, keychain: keychain, localState: localState, biometry: biometry,
                       camera: camera, notifications: notifications, cloud: factory, clock: clock,
                       approvals: approvalStore, deviceName: { "iPhone" })
    }

    /// The Mac most tests pair with.
    var primaryMac: MacPeer { MacPeer(identity: macIdentity, messenger: mac, name: Self.macName) }

    /// Another Mac on the same account.
    func makeMac(name: String) -> MacPeer {
        let identity = SoftwareIdentity()
        return MacPeer(identity: identity, messenger: makeMessenger(for: identity), name: name)
    }

    private func makeMessenger(for identity: SoftwareIdentity) -> DeviceMessenger {
        DeviceMessenger(identity: identity, platform: .macOS, registry: PairedDeviceRegistry(store: InMemoryListStore()),
                        transport: cloud.transport(for: identity.deviceID), clock: macClock,
                        approvalHandler: macInbox.handler)
    }

    /// The iPhone's identity once the welcome checks created it.
    var phone: SoftwareIdentity {
        get throws { try XCTUnwrap(identities.latest) }
    }

    /// A CloudKit query notification's payload, as the system delivers it.
    nonisolated static func pushPayload(subscription: String, zone: String, record: String) -> [AnyHashable: Any] {
        [
            "aps": ["alert": ["title-loc-key": "push.message.title", "loc-key": "push.message.body"], "mutable-content": 1],
            "ck": [
                "ce": 2,
                "cid": "iCloud.com.sudohg.askkey",
                "nid": UUID().uuidString,
                "qry": ["dbs": 1, "fo": 1, "rid": record, "sid": subscription, "zid": zone, "zoid": "_defaultOwner"],
            ] as [String: Any],
        ]
    }

    /// The payload of the alert push for a message in `device`'s inbox.
    nonisolated static func alertPush(for device: DeviceID, record: String) -> [AnyHashable: Any] {
        let zone = CloudKitInboxLayout.zoneName(for: device)
        return pushPayload(subscription: zone + "_alert", zone: zone, record: record)
    }

    /// Launches the app and passes the welcome checks.
    func setUpPhone(file: StaticString = #filePath, line: UInt = #line) async {
        await model.start()
        await model.runWelcomeChecks()
        XCTAssertEqual(model.stage, .ready, file: file, line: line)
    }

    /// Starts pairing on the Mac and scans its QR code on the iPhone.
    func scanMacCode(_ peer: MacPeer? = nil) async throws -> PairingFlowModel {
        let peer = peer ?? primaryMac
        let qr = try await peer.messenger.startPairing(displayName: peer.name)
        model.startPairing()
        let flow = try XCTUnwrap(model.pairing)
        await flow.handleScanned(qr.text)
        return flow
    }

    /// Runs pairing up to the code on the iPhone: the Mac answers the
    /// request, and the iPhone verifies the challenge and saves its reveal.
    func reachCode(_ peer: MacPeer? = nil) async throws -> (PairingFlowModel, PairingCodeDisplay) {
        let peer = peer ?? primaryMac
        let flow = try await scanMacCode(peer)
        _ = try await peer.messenger.poll()
        await flow.refresh()
        guard case .code(let display) = flow.stage else {
            XCTFail("expected the code, got \(flow.stage)")
            throw CancellationError()
        }
        return (flow, display)
    }

    /// Completes pairing on both sides.
    func pair(_ peer: MacPeer? = nil) async throws {
        let peer = peer ?? primaryMac
        let (flow, display) = try await reachCode(peer)
        _ = try await peer.messenger.poll()
        try await peer.messenger.enterPairingCode(display.digits)
        try await peer.messenger.confirmPairing(approvalReason: "Pair")
        await flow.confirm()
        await flow.refresh()
        _ = try await peer.messenger.poll()
        XCTAssertEqual(flow.stage, .paired(macName: peer.name))
        await model.closePairingAndWait()
    }
}
