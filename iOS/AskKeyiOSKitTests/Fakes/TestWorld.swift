import AskKeyDevices
import Foundation
import XCTest
@testable import AskKeyiOSKit

/// One iPhone app with fakes for keys, keychain and transport, and a Mac
/// played by a real `DeviceMessenger` on the same in-memory account.
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
    private(set) lazy var model = AppModel(environment: environment)

    let macIdentity = SoftwareIdentity()
    private(set) lazy var mac = DeviceMessenger(identity: macIdentity, platform: .macOS,
                                                registry: PairedDeviceRegistry(store: InMemoryListStore()),
                                                transport: cloud.transport(for: macIdentity.deviceID), clock: clock)
    static let macName = "Studio Mac"

    init() {
        factory = FakeCloudFactory(cloud: cloud)
    }

    var environment: AppEnvironment {
        AppEnvironment(identities: identities, keychain: keychain, localState: localState, biometry: biometry,
                       camera: camera, notifications: notifications, cloud: factory, clock: clock,
                       deviceName: { "iPhone" })
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
    func scanMacCode() async throws -> PairingFlowModel {
        let qr = try await mac.startPairing(displayName: Self.macName)
        model.startPairing()
        let flow = try XCTUnwrap(model.pairing)
        await flow.handleScanned(qr.text)
        return flow
    }

    /// Runs pairing up to the code on the iPhone: the Mac answers the
    /// request, and the iPhone verifies the challenge and saves its reveal.
    func reachCode() async throws -> (PairingFlowModel, PairingCodeDisplay) {
        let flow = try await scanMacCode()
        _ = try await mac.poll()
        await flow.refresh()
        guard case .code(let display) = flow.stage else {
            XCTFail("expected the code, got \(flow.stage)")
            throw CancellationError()
        }
        return (flow, display)
    }

    /// Completes pairing on both sides.
    func pair() async throws {
        let (flow, display) = try await reachCode()
        _ = try await mac.poll()
        try await mac.enterPairingCode(display.digits)
        try await mac.confirmPairing(approvalReason: "Pair")
        await flow.confirm()
        await flow.refresh()
        _ = try await mac.poll()
        XCTAssertEqual(flow.stage, .paired(macName: Self.macName))
        await model.closePairingAndWait()
    }
}
