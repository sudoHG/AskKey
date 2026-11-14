@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import CloudKit
import XCTest

/// Fetching known records by name (ADR 0014 → Polling the known records;
/// #310 acceptance 4).
final class NamedFetchTests: XCTestCase {
    private func decisionReady(_ fixture: ApprovalFixture) async throws -> (SealedApprovalRequest, SealedDeviceMessage) {
        let request = try await fixture.sendRequest()
        try await fixture.phone.poll()
        let decision = try await fixture.phone.messenger.sealer.sealApprovalDecision(.allowOnce,
                                                                                    answering: try fixture.phoneRequest(),
                                                                                    approvalReason: "Allow")
        try await fixture.harness.transport.send(decision.envelope)
        return (request, decision)
    }

    func testAMissingNameIsNotYetWithoutAnError() async throws {
        let fixture = try await ApprovalFixture.make()
        let request = try await fixture.sendRequest()
        let names = [request.request.responseID.text, ApprovalReceipt.receiptID(for: request.request.responseID).text]
        let report = try await fixture.mac.messenger.fetchNamedMessages(names)
        XCTAssertEqual(Set(report.notYet), Set(names))
        XCTAssertEqual(report.outcomes, [:])
        XCTAssertNil(report.retryAfter)
        XCTAssertEqual(fixture.harness.transport.namedFetchRequests, [names])
    }

    func testAFoundDecisionIsHandledDeletedAndLeavesTheChangeTokenUnchanged() async throws {
        let fixture = try await ApprovalFixture.make()
        let (request, decision) = try await decisionReady(fixture)
        let token = await fixture.mac.messenger.inboxToken
        let receiptName = ApprovalReceipt.receiptID(for: request.request.responseID).text
        let report = try await fixture.mac.messenger.fetchNamedMessages([decision.envelope.recordName, receiptName])
        XCTAssertEqual(report.outcomes, [decision.envelope.recordName: .processed])
        XCTAssertEqual(report.notYet, [receiptName])
        await XCTAssertEqualAsync(await fixture.mac.messenger.inboxToken, token, "the named fetch never moves the token")
        XCTAssertEqual(fixture.harness.transport.records(in: fixture.mac.id), [], "processed and deleted")
        XCTAssertEqual(fixture.outstanding.applied.map(\.messageID), [request.request.responseID])
        await XCTAssertEqualAsync(try await fixture.mac.poll().processed, 0, "the zone poll finds nothing left")
    }

    func testAFoundRecordPassesTheSameRules() async throws {
        let fixture = try await ApprovalFixture.make()
        let (request, decision) = try await decisionReady(fixture)
        // A writer to the account deletes the decision and writes another under its name.
        fixture.harness.transport.deleteRecord(named: decision.envelope.recordName, from: fixture.mac.id)
        var junk = decision.envelope
        junk.body[junk.body.count - 1] ^= 1
        fixture.harness.transport.insert(junk, intoInboxOf: fixture.mac.id)
        let token = await fixture.mac.messenger.inboxToken
        let report = try await fixture.mac.messenger.fetchNamedMessages([decision.envelope.recordName])
        XCTAssertEqual(report.outcomes, [decision.envelope.recordName: .refused(.decryptionFailed)])
        XCTAssertEqual(fixture.harness.transport.records(in: fixture.mac.id), [], "refused and deleted")
        await XCTAssertEqualAsync(await fixture.mac.messenger.inboxToken, token)
        XCTAssertNotNil(fixture.outstanding.entry(request.request.responseID), "no effect")
        // The phone sends the same bytes again; now the decision applies.
        try await fixture.harness.transport.send(decision.envelope)
        let retried = try await fixture.mac.messenger.fetchNamedMessages([decision.envelope.recordName])
        XCTAssertEqual(retried.outcomes, [decision.envelope.recordName: .processed])
    }

    func testARecordSeenByTheNamedFetchAndTheZonePollTakesEffectOnce() async throws {
        let fixture = try await ApprovalFixture.make()
        let (request, decision) = try await decisionReady(fixture)
        let gate = Gate()
        fixture.outstanding.beforeHandling = { await gate.wait() }
        let polling = Task { try await fixture.mac.poll() }
        try await gate.waitForArrivals(1)

        // The poll holds the message ID while its handler runs; the named fetch neither handles nor deletes it.
        let named = try await fixture.mac.messenger.fetchNamedMessages([decision.envelope.recordName])
        XCTAssertEqual(named.outcomes, [decision.envelope.recordName: .failed])
        XCTAssertEqual(gate.arrived, 1, "the handler ran once")
        XCTAssertEqual(fixture.harness.transport.records(in: fixture.mac.id).count, 1)

        gate.open()
        let report = try await polling.value
        XCTAssertEqual(report.processed, 1)
        XCTAssertEqual(fixture.outstanding.messages.count, 1)
        XCTAssertEqual(fixture.outstanding.applied.map(\.messageID), [request.request.responseID])
        let after = try await fixture.mac.messenger.fetchNamedMessages([decision.envelope.recordName])
        XCTAssertEqual(after.notYet, [decision.envelope.recordName])

        // A copy re-inserted later, by either path, is a replay.
        fixture.harness.transport.insert(decision.envelope, intoInboxOf: fixture.mac.id)
        let replayed = try await fixture.mac.messenger.fetchNamedMessages([decision.envelope.recordName])
        XCTAssertEqual(replayed.outcomes, [decision.envelope.recordName: .refused(.replayed)])
        XCTAssertEqual(fixture.outstanding.messages.count, 1)
    }

    func testHandlerFailuresCountTowardTheLimitOnBothPaths() async throws {
        let harness = DeviceHarness()
        let failing = FailingHandler()
        let mac = harness.makeDevice(.macOS, approvalHandler: failing.handler)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        harness.clock.advance(by: 11 * 60)
        let confirmation = try await phone.messenger.sealer.sealApproverConfirmation(
            ApproverCode.random(), to: try await XCTUnwrapAsync(try await phone.entry(for: mac)), approvalReason: "Approve")
        try await harness.transport.send(confirmation.envelope)
        let name = confirmation.envelope.recordName

        let first = try await mac.poll()
        XCTAssertEqual(first.outcomes[name], .failed)
        let token = await mac.messenger.inboxToken
        let second = try await mac.messenger.fetchNamedMessages([name])
        XCTAssertEqual(second.outcomes[name], .failed)
        XCTAssertEqual(harness.transport.records(in: mac.id).count, 1, "a failed message stays")
        await XCTAssertEqualAsync(await mac.messenger.inboxToken, token)
        let third = try await mac.poll()
        XCTAssertEqual(third.outcomes[name], .refused(.repeatedFailure))
        XCTAssertEqual(harness.transport.records(in: mac.id), [])
        XCTAssertEqual(failing.calls, 3)
    }

    func testATransportWithoutNamedFetchIsReported() async throws {
        let harness = DeviceHarness()
        harness.makeTransport = { _, _ in PlainTransport() }
        let mac = harness.makeDevice(.macOS)
        do {
            _ = try await mac.messenger.fetchNamedMessages([MessageID.random().text])
            XCTFail("no named fetch")
        } catch {
            XCTAssertEqual(error as? DeviceMessengerError, .namedFetchUnavailable)
        }
    }

    // MARK: CloudKit

    private let service = FakeCloudKitService()
    private let log = CloudKitEventLog()

    private func cloudTransport(for device: DeviceID, clock: any DeviceClock = ManualDeviceClock()) -> CloudKitDeviceTransport {
        CloudKitDeviceTransport(service: service, deviceID: device, platform: .macOS, clock: clock, log: log.sink)
    }

    func testCloudKitFetchesInBatchesOfAtMostOneHundred() async throws {
        let device = SoftwareDeviceIdentity().deviceID
        let transport = cloudTransport(for: device)
        _ = try await transport.prepareInbox()
        let names = (0..<250).map { _ in MessageID.random().text }
        let fetch = try await transport.fetchMessages(named: names + names.prefix(10), from: device)
        XCTAssertEqual(service.recordFetchBatches.map(\.count), [100, 100, 50], "duplicates are asked for once")
        XCTAssertEqual(service.recordFetchBatches.flatMap { $0 }, names)
        XCTAssertEqual(fetch.missingRecordNames, names)
        XCTAssertTrue(fetch.envelopes.isEmpty && fetch.failedRecordNames.isEmpty)
    }

    func testCloudKitResultsArePerRecord() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let transport = cloudTransport(for: mac.id)
        _ = try await transport.prepareInbox()
        let zoneID = CloudKitInboxLayout.zoneID(for: mac.id)
        let envelope = try PairingRuleTests.seal(.approvalReceipt, Data(count: 49), from: phone, to: mac, harness: harness)
        service.insert(try CloudKitMessageRecord.record(for: envelope))
        let malformedName = MessageID.random().text
        let malformed = CKRecord(recordType: "QuietMessage", recordID: CKRecord.ID(recordName: malformedName, zoneID: zoneID))
        malformed["sender"] = "x" as NSString
        service.insert(malformed)
        let missing = MessageID.random().text
        let failing = MessageID.random().text
        let limited = MessageID.random().text
        service.recordFetchErrors = [failing: CKError(.networkFailure),
                                     limited: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 4.0])]
        let fetch = try await transport.fetchMessages(named: [envelope.recordName, malformedName, missing, failing, limited,
                                                              "not-a-message-id"], from: mac.id)
        XCTAssertEqual(fetch.envelopes, [envelope])
        XCTAssertEqual(fetch.malformedRecordNames, [malformedName])
        XCTAssertEqual(fetch.missingRecordNames, ["not-a-message-id", missing])
        XCTAssertEqual(fetch.failedRecordNames, [failing, limited])
        XCTAssertEqual(fetch.retryAfter, 4)
        XCTAssertFalse(service.recordFetchBatches.flatMap { $0 }.contains("not-a-message-id"), "no request for it")
    }

    func testCloudKitRequestThatFailsAsAWholeThrowsItsTransportError() async throws {
        let device = SoftwareDeviceIdentity().deviceID
        let transport = cloudTransport(for: device)
        _ = try await transport.prepareInbox()
        service.recordFetchError = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 7.0])
        do {
            _ = try await transport.fetchMessages(named: [MessageID.random().text], from: device)
            XCTFail("throws")
        } catch {
            XCTAssertEqual(error as? DeviceTransportError, .rateLimited(retryAfter: 7))
        }
        service.recordFetchError = CKError(.networkUnavailable)
        do {
            _ = try await transport.fetchMessages(named: [MessageID.random().text], from: device)
            XCTFail("throws")
        } catch {
            XCTAssertEqual(error as? DeviceTransportError, .networkUnavailable)
        }
    }

    func testCloudKitRecreatesAMissingOwnZoneAndLogsIt() async throws {
        for wholeRequest in [false, true] {
            let device = SoftwareDeviceIdentity().deviceID
            let transport = cloudTransport(for: device)
            _ = try await transport.prepareInbox()
            let zone = CloudKitInboxLayout.zoneID(for: device).zoneName
            service.removeZone(named: zone)
            service.recordFetchError = wholeRequest ? CKError(.zoneNotFound) : nil
            let name = MessageID.random().text
            let fetch = try await transport.fetchMessages(named: [name], from: device)
            service.recordFetchError = nil
            XCTAssertEqual(fetch.missingRecordNames, [name], "a missing zone holds nothing yet")
            XCTAssertTrue(service.zoneNames.contains(zone), "created again")
            XCTAssertEqual(log.events.filter { if case .inboxZoneRecreated = $0 { return true } else { return false } }.count,
                           wholeRequest ? 2 : 1)
        }
    }

    func testMessengerOverCloudKitHandlesANamedDecisionOnce() async throws {
        let fixtureService = service
        let fixture = ApprovalFixture()
        fixture.harness.makeTransport = { [log, clock = fixture.harness.clock] device, platform in
            CloudKitDeviceTransport(service: fixtureService, deviceID: device, platform: platform, clock: clock, log: log.sink)
        }
        try await fixture.setUp { [service, log, clock = fixture.harness.clock] device in
            _ = try await CloudKitDeviceTransport(service: service, deviceID: device.id, platform: device.platform,
                                                  clock: clock, log: log.sink).prepareInbox()
        }
        let request = try await fixture.mac.messenger.sealer.sealApprovalRequest(
            ApprovalVectorTests.vectorDisplay, bindingDigest: ApprovalFixture.binding,
            deadline: fixture.harness.clock.now().addingTimeInterval(60), launchTime: fixture.harness.clock.now(),
            offers: .denyOrAllowOnce, timedDuration: 0, to: try await fixture.macEntryForPhone())
        fixture.outstanding.record(request, to: fixture.phone.id)
        try await cloudTransport(for: fixture.mac.id).send(request.sealed.envelope)
        try await fixture.phone.poll()
        let deny = try await fixture.phone.messenger.sealer.sealApprovalDecision(.deny, answering: try fixture.phoneRequest(),
                                                                                approvalReason: "Deny")
        try await cloudTransport(for: fixture.phone.id).send(deny.envelope)
        try await cloudTransport(for: fixture.phone.id).send(deny.envelope) // A resend finds the record and counts as sent.
        let token = await fixture.mac.messenger.inboxToken
        let report = try await fixture.mac.messenger.fetchNamedMessages([request.request.responseID.text])
        XCTAssertEqual(report.outcomes, [request.request.responseID.text: .processed])
        await XCTAssertEqualAsync(await fixture.mac.messenger.inboxToken, token)
        XCTAssertEqual(service.records(inZone: CloudKitInboxLayout.zoneID(for: fixture.mac.id).zoneName), [])
        await XCTAssertEqualAsync(try await fixture.mac.poll().processed, 0)
        XCTAssertEqual(fixture.outstanding.applied.count, 1)
    }
}

/// An approval handler that always fails.
private final class FailingHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.withLock { count } }

    var handler: ApprovalMessageHandler {
        { [self] _ in
            lock.withLock { count += 1 }
            return .failed
        }
    }
}

/// A transport that only has `DeviceTransport`'s requirements.
private struct PlainTransport: DeviceTransport {
    func send(_ envelope: DeviceEnvelope) async throws {}

    func fetchInboxChanges(of device: DeviceID, since token: InboxChangeToken?) async throws -> InboxChanges {
        InboxChanges(envelopes: [], newToken: InboxChangeToken(data: Data()))
    }

    func deleteMessages(_ recordNames: [String], from device: DeviceID) async throws {}
}
