import AskKeyDevices
import Foundation
import XCTest
@testable import AskKeyiOSKit

/// The approver's stored state in memory; writes can be made to fail.
final class InMemoryApprovalStore: ApprovalStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var failWrites = false
    private var failReads = false

    var writesFail: Bool {
        get { lock.withLock { failWrites } }
        set { lock.withLock { failWrites = newValue } }
    }

    /// Reading fails as an I/O error would, while the stored bytes stay.
    var readsFail: Bool {
        get { lock.withLock { failReads } }
        set { lock.withLock { failReads = newValue } }
    }

    /// The stored bytes, as the file would hold them.
    var storedData: Data? { lock.withLock { data } }

    var stored: StoredApprovals {
        guard let data = storedData else { return StoredApprovals() }
        return (try? JSONDecoder().decode(StoredApprovals.self, from: data)) ?? StoredApprovals()
    }

    func loadApprovals() throws -> Data? {
        try lock.withLock {
            if failReads { throw CocoaError(.fileReadUnknown) }
            return data
        }
    }

    func saveApprovals(_ data: Data) throws {
        try lock.withLock {
            if failWrites { throw CocoaError(.fileWriteNoPermission) }
            self.data = data
        }
    }

    func removeApprovals() throws {
        lock.withLock { data = nil }
    }
}

/// A Mac's clock: the shared manual clock plus an offset, so a test can
/// run the Mac minutes fast or slow against the iPhone.
final class OffsetClock: DeviceClock, @unchecked Sendable {
    private let base: ManualClock
    private let lock = NSLock()
    private var current: TimeInterval = 0

    init(base: ManualClock) {
        self.base = base
    }

    var offset: TimeInterval {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func now() -> Date { base.now().addingTimeInterval(offset) }
}

/// Records what the Macs' messengers verified, and accepts all of it.
final class MacInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [VerifiedApprovalMessage] = []

    var messages: [VerifiedApprovalMessage] { lock.withLock { received } }

    var handler: ApprovalMessageHandler {
        { [weak self] message in
            self?.lock.withLock { self?.received.append(message) }
            return .processed
        }
    }
}

/// A value a `@Sendable` test closure can set.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension TestWorld {
    /// Synthetic request content; no real credential.
    static let sampleDisplay = ApprovalRequestDisplay(
        requesterName: "Codex", purpose: "Deploy the preview site", credentialName: "GitHub Token",
        commandLine: "./deploy.sh --prod --region eu-west-1", workingDirectory: "~/src/app", executableName: "deploy.sh",
        deliveryRows: [ApprovalDeliveryRow(kind: .environmentVariable, label: "", variable: "GITHUB_TOKEN")])
    static let macLaunch = Date(timeIntervalSince1970: 1_799_990_000)
    static let approverCode = "123 456"

    /// Turns approval on for the Mac on this iPhone through the approver
    /// confirmation: the code, Face ID, the confirmation, then the flag.
    func approveMac(_ peer: MacPeer? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        let peer = peer ?? primaryMac
        model.startApproverConfirmation(macID: peer.deviceID.text)
        await model.confirmApprover(typed: Self.approverCode)
        XCTAssertEqual(model.approverConfirmation?.stage, .sent, file: file, line: line)
        model.closeApproverConfirmation()
    }

    /// Pairs another Mac and turns approval on for it.
    func pairAndApprove(_ peer: MacPeer) async throws {
        try await pair(peer)
        await approveMac(peer)
    }

    /// The Mac's entry for this iPhone.
    func phoneEntry(on peer: MacPeer? = nil) async throws -> PairedDevice {
        let peer = peer ?? primaryMac
        let phoneID = try phone.deviceID
        let entry = try await peer.messenger.pairedDevices().first { $0.deviceID == phoneID }
        return try XCTUnwrap(entry)
    }

    /// Seals a request on the Mac's clock, as the Mac's coordinator would.
    func sealRequest(from peer: MacPeer? = nil, display: ApprovalRequestDisplay = TestWorld.sampleDisplay,
                     lifetime: TimeInterval = 300, launchTime: Date = TestWorld.macLaunch,
                     offers: ApprovalOffers = .denyOrAllowOnce, timedDuration: UInt64 = 0) async throws -> SealedApprovalRequest {
        let peer = peer ?? primaryMac
        let entry = try await phoneEntry(on: peer)
        return try peer.messenger.sealer.sealApprovalRequest(display, bindingDigest: Data(repeating: 0xAB, count: 32),
                                                             deadline: macClock.now().addingTimeInterval(lifetime),
                                                             launchTime: launchTime, offers: offers,
                                                             timedDuration: timedDuration, to: entry)
    }

    /// Seals a request and writes it into the iPhone's inbox.
    @discardableResult
    func sendRequest(from peer: MacPeer? = nil, display: ApprovalRequestDisplay = TestWorld.sampleDisplay,
                     lifetime: TimeInterval = 300, launchTime: Date = TestWorld.macLaunch,
                     offers: ApprovalOffers = .denyOrAllowOnce, timedDuration: UInt64 = 0) async throws -> SealedApprovalRequest {
        let sealed = try await sealRequest(from: peer, display: display, lifetime: lifetime, launchTime: launchTime,
                                           offers: offers, timedDuration: timedDuration)
        try await deliver(sealed.sealed.envelope)
        return sealed
    }

    /// The Mac's approval-closed message for a request.
    @discardableResult
    func sendClosed(_ outcome: ApprovalClosedOutcome, code: ApprovalDecisionCode? = nil, duration: UInt64 = 0,
                    for request: SealedApprovalRequest, from peer: MacPeer? = nil) async throws -> SealedDeviceMessage {
        let peer = peer ?? primaryMac
        let sealed = try peer.messenger.sealer.sealApprovalClosed(outcome, appliedCode: code, appliedDuration: duration,
                                                                  requestDigest: request.requestDigest,
                                                                  to: try await phoneEntry(on: peer))
        try await deliver(sealed.envelope)
        return sealed
    }

    func deliver(_ envelope: DeviceEnvelope) async throws {
        try await cloud.transport(for: try XCTUnwrap(DeviceID(text: envelope.sender))).send(envelope)
    }

    /// The decisions in a Mac's inbox, verified as the Mac verifies them.
    func decisions(on peer: MacPeer? = nil) async throws -> [(message: VerifiedApprovalMessage, decision: ApprovalDecision)] {
        let peer = peer ?? primaryMac
        let list = try PairedDeviceList(devices: try await peer.messenger.pairedDevices())
        let verifier = DeviceMessageVerifier(identity: peer.identity, list: list)
        return try cloud.records(in: peer.deviceID).filter { $0.kind == Int64(MessageKind.approvalDecision.rawValue) }
            .compactMap { envelope in
                guard case .approval(let message) = try verifier.verify(envelope, now: macClock.now()),
                      case .decision(let decision) = message.message else { return nil }
                return (message, decision)
            }
    }

    /// Every attempt to send a decision, failed ones included.
    func decisionAttempts() throws -> [DeviceEnvelope] {
        cloud.sent(.approvalDecision, from: try phone.deviceID)
    }

    var card: RequestCard? { model.requests.first }
}
