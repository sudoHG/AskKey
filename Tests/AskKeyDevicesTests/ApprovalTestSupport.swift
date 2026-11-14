@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import CryptoKit
import XCTest

/// Records what an approval handler receives and answers `processed`.
final class ApprovalInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [VerifiedApprovalMessage] = []

    var messages: [VerifiedApprovalMessage] { lock.withLock { received } }

    var handler: ApprovalMessageHandler {
        { [self] message in
            lock.withLock { received.append(message) }
            return .processed
        }
    }
}

/// Stands in for the Mac App's outstanding table (ADR 0014 → Verifying and
/// applying a decision): it checks steps 2, 4 and 5 of a decision, and a
/// receipt's ID and digest, and the first decision that passes consumes the
/// entry.
final class OutstandingRequests: @unchecked Sendable {
    struct Entry {
        let approver: DeviceID
        let digest: Data
        let offers: ApprovalOffers
        let timedDuration: UInt64
        var delivered = false
    }

    private let lock = NSLock()
    private var entries: [MessageID: Entry] = [:]
    private var received: [VerifiedApprovalMessage] = []
    private var appliedDecisions: [VerifiedApprovalMessage] = []
    private var hold: (@Sendable () async -> Void)?

    var messages: [VerifiedApprovalMessage] { lock.withLock { received } }
    var applied: [VerifiedApprovalMessage] { lock.withLock { appliedDecisions } }

    func entry(_ responseID: MessageID) -> Entry? { lock.withLock { entries[responseID] } }

    /// Runs before each message is handled, for example to hold the handler open.
    var beforeHandling: (@Sendable () async -> Void)? {
        get { lock.withLock { hold } }
        set { lock.withLock { hold = newValue } }
    }

    func record(_ sealed: SealedApprovalRequest, to approver: DeviceID) {
        lock.withLock {
            entries[sealed.request.responseID] = Entry(approver: approver, digest: sealed.requestDigest,
                                                        offers: sealed.request.offers,
                                                        timedDuration: sealed.request.timedDuration)
        }
    }

    var handler: ApprovalMessageHandler {
        { [self] message in
            await beforeHandling?()
            return lock.withLock { handle(message) }
        }
    }

    private func handle(_ message: VerifiedApprovalMessage) -> ApprovalMessageHandling {
        received.append(message)
        switch message.message {
        case .decision(let decision):
            // Step 2: an outstanding request for this sender whose response ID is the message ID.
            guard let entry = entries[message.messageID], entry.approver == message.senderID else {
                return .refused(.bindingMismatch)
            }
            // Step 4: the digest recorded at sealing.
            guard decision.requestDigest == entry.digest else { return .refused(.bindingMismatch) }
            // Step 5: an offered code, and for code 2 the offered duration.
            guard entry.offers.contains(decision.code),
                  decision.code != .timedAllowance || decision.durationCeiling == entry.timedDuration else {
                return .refused(.bindingMismatch)
            }
            entries[message.messageID] = nil
            appliedDecisions.append(message)
            return .processed
        case .receipt(let receipt):
            guard let (responseID, entry) = entries.first(where: { ApprovalReceipt.receiptID(for: $0.key) == message.messageID }),
                  entry.approver == message.senderID, receipt.requestDigest == entry.digest else {
                return .refused(.bindingMismatch)
            }
            entries[responseID]?.delivered = true
            return .processed
        case .confirmation:
            return .processed
        case .request, .closed:
            return .refused(.unexpectedKind)
        }
    }
}

/// Suspends callers until it is opened.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var arrivals = 0

    var arrived: Int { lock.withLock { arrivals } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                arrivals += 1
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }

    /// Waits until `count` callers arrived, failing after about two seconds.
    func waitForArrivals(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 where arrived < count {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThanOrEqual(arrived, count, "callers arrived", file: file, line: line)
    }
}

/// A Mac and an iPhone paired over the in-memory transport, with the
/// Mac's outstanding table and the iPhone's inbox as their handlers, and
/// the approval flag on in both lists.
final class ApprovalFixture {
    let harness = DeviceHarness()
    let outstanding = OutstandingRequests()
    let phoneInbox = ApprovalInbox()
    private(set) var mac: SimulatedDevice!
    private(set) var phone: SimulatedDevice!
    let removals = RemovalLog()

    static func make() async throws -> ApprovalFixture {
        let fixture = ApprovalFixture()
        try await fixture.setUp()
        return fixture
    }

    /// Makes both devices, runs `beforePairing` for each, pairs them and
    /// turns the approval flag on in both lists.
    func setUp(beforePairing: ((SimulatedDevice) async throws -> Void)? = nil) async throws {
        mac = harness.makeDevice(.macOS, approvalHandler: outstanding.handler, removalHook: removals.hook(fixture: self))
        phone = harness.makeDevice(.iOS, approvalHandler: phoneInbox.handler)
        for device in [mac!, phone!] { try await beforePairing?(device) }
        try await harness.pair(mac, phone)
        harness.clock.advance(by: 11 * 60) // Past every pairing message's lifetime.
        for (device, other) in [(mac!, phone!), (phone!, mac!)] {
            let entry = try await XCTUnwrapAsync(try await device.entry(for: other))
            try await PairedDeviceRegistry(store: device.store).apply(.setApprover(other.id, pairingID: entry.pairingID,
                                                                                   enabled: true))
        }
    }

    /// The same phone, keys and list, restarted with its clock `offset` seconds off.
    func restartPhone(clockOffset offset: TimeInterval) {
        phone = SimulatedDevice(identity: phone.identity, store: phone.store, platform: .iOS, harness: harness,
                                options: .init(clockOffset: offset, approvalHandler: phoneInbox.handler))
    }

    func macEntryForPhone() async throws -> PairedDevice {
        try await XCTUnwrapAsync(try await mac.entry(for: phone))
    }

    func phoneEntryForMac() async throws -> PairedDevice {
        try await XCTUnwrapAsync(try await phone.entry(for: mac))
    }

    func handled(by device: SimulatedDevice) -> Int {
        device === mac ? outstanding.messages.count : phoneInbox.messages.count
    }

    /// The stateless verifier gives `refusal` (or, for a message that
    /// reaches the handler, a verified message) without deleting anything or
    /// writing the list; then a poll refuses it with the same refusal,
    /// deletes it and changes nothing.
    func assertRefused(_ envelope: DeviceEnvelope, at device: SimulatedDevice, _ refusal: DeviceMessageRefusal,
                       reachesHandler: Bool = false, checkVerifier: Bool = true,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        harness.transport.insert(envelope, intoInboxOf: device.id)
        let storedList = device.store.storedBytes
        if checkVerifier {
            let verifier = DeviceMessageVerifier(identity: device.identity, list: try device.store.loadPairedDeviceList())
            let verdict = try verifier.verify(envelope, now: device.clock.now())
            if reachesHandler {
                guard case .approval = verdict else { return XCTFail("verified, got \(verdict)", file: file, line: line) }
            } else {
                XCTAssertEqual(verdict, .refused(refusal), "the stateless verifier's verdict", file: file, line: line)
            }
            XCTAssertEqual(harness.transport.records(in: device.id).map(\.recordName), [envelope.recordName],
                           "the verifier deletes nothing", file: file, line: line)
            XCTAssertEqual(device.store.storedBytes, storedList, "the verifier writes no list", file: file, line: line)
        }
        let handledBefore = handled(by: device)
        let appliedBefore = outstanding.applied.count
        let report = try await device.poll()
        XCTAssertEqual(report.refusals, [refusal], file: file, line: line)
        XCTAssertEqual(report.processed, 0, file: file, line: line)
        XCTAssertEqual(harness.transport.records(in: device.id), [], "refused and deleted", file: file, line: line)
        XCTAssertEqual(handled(by: device), handledBefore + (reachesHandler ? 1 : 0), "reaches the handler: \(reachesHandler)",
                       file: file, line: line)
        XCTAssertEqual(device.store.storedBytes, storedList, "the list is unchanged", file: file, line: line)
        XCTAssertEqual(outstanding.applied.count, appliedBefore, "nothing was applied", file: file, line: line)
    }

    static let binding = Data(SHA256.hash(data: Data("synthetic binding".utf8)))

    /// Seals a request on the Mac, records it in the outstanding table and sends it.
    @discardableResult
    func sendRequest(offers: ApprovalOffers = .all, timedDuration: UInt64 = 1_800,
                     deadlineIn: TimeInterval = 120) async throws -> SealedApprovalRequest {
        let sealed = try mac.messenger.sealer.sealApprovalRequest(
            ApprovalVectorTests.vectorDisplay, bindingDigest: Self.binding,
            deadline: mac.clock.now().addingTimeInterval(deadlineIn), launchTime: Date(timeIntervalSince1970: 1_799_000_000),
            offers: offers, timedDuration: offers.contains(.timedAllowance) ? timedDuration : 0,
            to: try await macEntryForPhone())
        outstanding.record(sealed, to: phone.id)
        try await harness.transport.send(sealed.sealed.envelope)
        return sealed
    }

    /// The request the phone verified last.
    func phoneRequest(file: StaticString = #filePath, line: UInt = #line) throws -> VerifiedApprovalMessage {
        try XCTUnwrap(phoneInbox.messages.last { if case .request = $0.message { return true } else { return false } },
                      "the phone verified a request", file: file, line: line)
    }

    /// Seals a payload of `kind` from `sender` to `recipient` with the
    /// sender's real message key, as a writer with that key could.
    static func seal(_ kind: MessageKind, _ payload: Data, from sender: SimulatedDevice, to recipient: SimulatedDevice,
                     messageID: MessageID = .random(), sentAt: Int64, lifetime: Int64 = 600) throws -> DeviceEnvelope {
        try MessageCodec.seal(kind: kind, payload: payload, identity: sender.identity, recipient: recipient.id,
                              recipientKey: recipient.identity.agreementPublicKey, preSharedKey: nil, sentAt: sentAt,
                              expiresAt: sentAt + lifetime, messageID: messageID).envelope
    }
}

/// Records each entry the removal hook receives, and whether the entry was
/// still in the stored list at that moment.
final class RemovalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(entry: PairedDevice, storedAtCall: Bool)] = []

    var entries: [PairedDevice] { lock.withLock { calls.map(\.entry) } }
    var allBeforeCommit: Bool { lock.withLock { calls.allSatisfy(\.storedAtCall) } }

    func hook(store: InMemoryPairedDeviceListStore) -> PairedDeviceRemovalHook {
        { [self] entry in
            let stored = (try? store.loadPairedDeviceList().devices.contains {
                $0.deviceID == entry.deviceID && $0.pairingID == entry.pairingID
            }) ?? false
            lock.withLock { calls.append((entry, stored)) }
        }
    }

    /// A hook for the fixture's Mac, whose store exists only once it is made.
    func hook(fixture: ApprovalFixture) -> PairedDeviceRemovalHook {
        { [self, weak fixture] entry in
            guard let store = fixture?.mac?.store else { return }
            await hook(store: store)(entry)
        }
    }
}
