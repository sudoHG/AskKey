import AskKeyDevices
import CloudKit
import Foundation
import UserNotifications
import XCTest

extension NotificationStrings {
    /// The compiled table of one language from this test bundle's copy of
    /// the extension's catalog.
    static func table(_ language: String) throws -> NotificationStrings {
        let table = try strings(language)
        return NotificationStrings { table[$0] ?? $0 }
    }

    static func strings(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle(for: TestIdentity.self).url(forResource: "Localizable", withExtension: "strings",
                                                                   subdirectory: nil, localization: language),
                                "the test bundle has no \(language) strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }
}

/// One iPhone with the extension's keychain, one or more Macs on its list,
/// and the account's private database, all in memory. The Macs seal with
/// the real sealer and write through the real CloudKit transport.
final class NotificationWorld {
    /// Synthetic request content; no real credential.
    static let sampleDisplay = ApprovalRequestDisplay(
        requesterName: "Codex", purpose: "Deploy the preview site", credentialName: "GitHub Token",
        commandLine: "./deploy.sh --prod --region eu-west-1", workingDirectory: "~/src/app", executableName: "deploy.sh",
        deliveryRows: [ApprovalDeliveryRow(kind: .environmentVariable, label: "", variable: "GITHUB_TOKEN")])

    struct Mac {
        let identity: TestIdentity
        let pairingID: PairingID
        /// The Mac's entry for this iPhone, which the Mac seals to.
        let phoneEntry: PairedDevice
        let listStore: TestListStore
    }

    let clock = TestClock()
    let cloud = TestCloudKit()
    let keychain = TestKeychain()
    let phone = TestIdentity()
    private(set) var macs: [Mac] = []
    private var phoneList = PairedDeviceList()
    var restoreFails = false
    var hasContainer = true

    var mac: Mac { macs[0] }

    init(macName: String = "Studio Mac", approver: Bool = true) throws {
        keychain.seed(phone.blobs.message, for: DeviceKeychainAccount.messageKey)
        keychain.seed(phone.blobs.agreement, for: DeviceKeychainAccount.agreementKey)
        keychain.seed(phone.blobs.approval, for: DeviceKeychainAccount.approvalKey)
        try addMac(named: macName, approver: approver)
    }

    /// Pairs another device (a Mac unless `platform` says otherwise) and
    /// stores the iPhone's list as the app would.
    @discardableResult
    func addMac(named name: String, approver: Bool = true, platform: DevicePlatform = .macOS) throws -> Mac {
        let identity = TestIdentity()
        let pairingID = try XCTUnwrap(PairingID(rawValue: Data((0..<16).map { _ in UInt8.random(in: 0...255) })))
        let card = try DeviceCard.make(identity: identity, platform: platform, createdAt: clock.now())
        try phoneList.apply(.add(PairedDevice(card: card, pairingID: pairingID, displayName: name, pairedAt: clock.now())))
        if approver { try phoneList.apply(.setApprover(identity.id, pairingID: pairingID, enabled: true)) }
        keychain.seed(try phoneList.serialized(), for: DeviceKeychainAccount.pairedDevices)
        let phoneCard = try DeviceCard.make(identity: phone, platform: .iOS, createdAt: clock.now())
        var macList = PairedDeviceList()
        try macList.apply(.add(PairedDevice(card: phoneCard, pairingID: pairingID, displayName: "Test iPhone",
                                            pairedAt: clock.now())))
        try macList.apply(.setApprover(phone.id, pairingID: pairingID, enabled: true))
        let mac = Mac(identity: identity, pairingID: pairingID, phoneEntry: try XCTUnwrap(macList.device(phone.id)),
                      listStore: try TestListStore(macList))
        macs.append(mac)
        return mac
    }

    /// Turns a Mac's approval flag on or off on this iPhone, as the app would.
    func setApprover(_ mac: Mac, enabled: Bool) throws {
        try phoneList.apply(.setApprover(mac.identity.id, pairingID: mac.pairingID, enabled: enabled))
        keychain.seed(try phoneList.serialized(), for: DeviceKeychainAccount.pairedDevices)
    }

    func environment(strings: NotificationStrings? = nil) throws -> NotificationEnvironment {
        let phone = phone
        let restoreFails = restoreFails
        let cloud = cloud
        let clock = clock
        let hasContainer = hasContainer
        return NotificationEnvironment(
            keychain: ExtensionKeychain(store: keychain),
            restoreIdentity: { blobs in
                guard !restoreFails, blobs == phone.blobs else { throw DeviceIdentityError.unusable }
                return phone
            },
            makeInbox: { device in
                guard hasContainer else { return nil }
                return CloudKitNotificationInbox(transport: CloudKitDeviceTransport(service: cloud, deviceID: device,
                                                                                    platform: .iOS, clock: clock,
                                                                                    log: { _ in }))
            },
            clock: clock,
            strings: try strings ?? .table("en"))
    }

    /// A request sealed on the Mac, as its coordinator would.
    func sealRequest(from mac: Mac? = nil, display: ApprovalRequestDisplay = NotificationWorld.sampleDisplay,
                     lifetime: TimeInterval = 300) throws -> SealedApprovalRequest {
        let mac = mac ?? self.mac
        return try DeviceMessageSealer(identity: mac.identity, clock: clock)
            .sealApprovalRequest(display, bindingDigest: Data(repeating: 0xAB, count: 32),
                                 deadline: clock.now().addingTimeInterval(lifetime),
                                 launchTime: Date(timeIntervalSince1970: 1_799_990_000), offers: .denyOrAllowOnce,
                                 timedDuration: 0, to: mac.phoneEntry)
    }

    /// Seals a request and writes it into the iPhone's inbox; returns it and its push.
    func sendRequest(from mac: Mac? = nil, display: ApprovalRequestDisplay = NotificationWorld.sampleDisplay)
        throws -> (request: SealedApprovalRequest, push: [AnyHashable: Any]) {
        let sealed = try sealRequest(from: mac, display: display)
        try cloud.insert(sealed.sealed.envelope)
        return (sealed, push(for: sealed.sealed.envelope.recordName))
    }

    /// The payload CloudKit sends for a record in `device`'s inbox
    /// (this iPhone's by default), with an alert an attacker could have chosen.
    func push(for recordName: String, device: DeviceID? = nil, subscription: String? = nil) -> [AnyHashable: Any] {
        let zone = CloudKitInboxLayout.zoneName(for: device ?? phone.id)
        let subscription = subscription ?? zone + "_alert"
        return [
            "aps": ["alert": ["title": "Ask Key", "subtitle": "Enter 123 456", "body": "Approve now"],
                    "mutable-content": 1, "category": "attacker.actions"] as [String: Any],
            "ck": [
                "ce": 2, "cid": "iCloud.com.sudohg.askkey", "nid": UUID().uuidString,
                "qry": ["dbs": 1, "fo": 1, "rid": recordName, "sid": subscription, "zid": zone, "zoid": "_defaultOwner"],
            ] as [String: Any],
            "extra": "Enter 123 456 on your Mac",
        ]
    }

    func process(_ userInfo: [AnyHashable: Any], strings: NotificationStrings? = nil) async throws -> NotificationDecision {
        await NotificationProcessor(environment: try environment(strings: strings)).process(PushInfo(userInfo: userInfo))
    }

    /// The detailed notification for a push; fails the test otherwise.
    func requestNotification(_ userInfo: [AnyHashable: Any], strings: NotificationStrings? = nil,
                             file: StaticString = #filePath, line: UInt = #line) async throws -> RequestNotification {
        let decision = try await process(userInfo, strings: strings)
        return try XCTUnwrap(decision.request, "\(decision)", file: file, line: line)
    }

    /// Everything the extension wrote into any Mac's inbox.
    var sent: [DeviceEnvelope] {
        macs.flatMap { cloud.envelopes(in: $0.identity.id) }
    }

    /// The Mac's own verifier for what it received.
    func verifyOnMac(_ envelope: DeviceEnvelope, mac: Mac? = nil) throws -> DeviceMessageVerdict {
        let mac = mac ?? self.mac
        return try DeviceMessageVerifier(identity: mac.identity, list: try mac.listStore.loadPairedDeviceList())
            .verify(envelope, now: clock.now())
    }

    /// Nothing the extension must never do happened: no deletion, no zone
    /// or subscription change, no approval key, no keychain write but its
    /// own item, no keychain deletion.
    func assertStayedInItsLane(file: StaticString = #filePath, line: UInt = #line) {
        let forbidden = ["deleteRecords", "saveZone", "deleteZone", "saveSubscription", "deleteSubscriptions",
                         "zoneExists", "fetchSubscriptions", "fetchChanges"]
        let calls = cloud.calls.filter { call in forbidden.contains { call.hasPrefix($0) } }
        XCTAssertEqual(calls, [], file: file, line: line)
        XCTAssertEqual(phone.approvalKeyUses, 0, file: file, line: line)
        XCTAssertEqual(Set(keychain.writes).subtracting([ExtensionKeychain.stateAccount]), [], file: file, line: line)
        XCTAssertEqual(keychain.deletions, [], file: file, line: line)
    }
}

extension NotificationDecision {
    var request: RequestNotification? {
        guard case .request(let request) = self else { return nil }
        return request
    }
}
