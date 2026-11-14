@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import XCTest

/// Clocks up to 5 minutes apart (ADR 0014 → Clocks and expiry; #310
/// acceptance 7): each device checks freshness on its own clock.
final class ApprovalClockTests: XCTestCase {
    func testTimelyRequestAndDecisionPassWithThePhoneTwoOrFourMinutesOff() async throws {
        for offset: TimeInterval in [-240, -120, 120, 240] {
            for deadlineIn: TimeInterval in [30, 300] {
                let fixture = try await ApprovalFixture.make()
                fixture.restartPhone(clockOffset: offset)
                let request = try await fixture.sendRequest(deadlineIn: deadlineIn)
                let received = try await fixture.phone.poll()
                XCTAssertEqual(received.processed, 1, "offset \(offset), deadline \(deadlineIn): the phone accepts the request")
                XCTAssertEqual(received.refusals, [])

                fixture.harness.clock.advance(by: min(20, deadlineIn - 5))
                let decision = try await fixture.phone.messenger.sealer.sealApprovalDecision(
                    .allowOnce, answering: try fixture.phoneRequest(), approvalReason: "Allow")
                XCTAssertEqual(decision.envelope.sentAt, fixture.harness.clock.now().addingTimeInterval(offset),
                               "sealed on the phone's clock")
                try await fixture.harness.transport.send(decision.envelope)
                let applied = try await fixture.mac.poll()
                XCTAssertEqual(applied.processed, 1, "offset \(offset): the Mac accepts the timely decision")
                XCTAssertEqual(fixture.outstanding.applied.map(\.messageID), [request.request.responseID])

                let receipt = try fixture.phone.messenger.sealer.sealApprovalReceipt(answering: try fixture.phoneRequest())
                let closed = try fixture.mac.messenger.sealer.sealApprovalClosed(
                    .applied, appliedCode: .allowOnce, requestDigest: request.requestDigest,
                    to: try await fixture.macEntryForPhone())
                try await fixture.harness.transport.send(receipt.envelope)
                try await fixture.harness.transport.send(closed.envelope)
                await XCTAssertEqualAsync(try await fixture.mac.poll().refusals, [.bindingMismatch],
                                          "offset \(offset): the receipt is fresh; only the consumed entry refuses it")
                await XCTAssertEqualAsync(try await fixture.phone.poll().processed, 1,
                                          "offset \(offset): the closed message is fresh")
            }
        }
    }

    func testASentTimeMoreThanFiveMinutesAheadIsRefused() async throws {
        // The phone runs 5 minutes and 1 second fast: its decision is from the Mac's future.
        let fast = try await ApprovalFixture.make()
        fast.restartPhone(clockOffset: 301)
        let request = try await fast.sendRequest(deadlineIn: 300)
        await XCTAssertEqualAsync(try await fast.phone.poll().processed, 1, "the request is fresh on the fast phone")
        let decision = try await fast.phone.messenger.sealer.sealApprovalDecision(.allowOnce,
                                                                                 answering: try fast.phoneRequest(),
                                                                                 approvalReason: "Allow")
        try await fast.assertRefused(decision.envelope, at: fast.mac, .sentInFuture)
        XCTAssertNotNil(fast.outstanding.entry(request.request.responseID), "no effect")

        // The phone runs 5 minutes and 1 second slow: the Mac's request is from the phone's future.
        let slow = try await ApprovalFixture.make()
        slow.restartPhone(clockOffset: -301)
        let late = try slow.mac.messenger.sealer.sealApprovalRequest(
            ApprovalVectorTests.vectorDisplay, bindingDigest: ApprovalFixture.binding,
            deadline: slow.harness.clock.now().addingTimeInterval(300), launchTime: slow.harness.clock.now(),
            offers: .denyOrAllowOnce, timedDuration: 0, to: try await slow.macEntryForPhone())
        try await slow.assertRefused(late.sealed.envelope, at: slow.phone, .sentInFuture)

        // Exactly 5 minutes ahead is still fresh.
        let edge = try await ApprovalFixture.make()
        edge.restartPhone(clockOffset: -300)
        try await edge.sendRequest(deadlineIn: 300)
        await XCTAssertEqualAsync(try await edge.phone.poll().processed, 1)
    }

    func testAMessagePastItsTransportExpiryOnTheRecipientsClockIsRefused() async throws {
        let fixture = try await ApprovalFixture.make()
        fixture.restartPhone(clockOffset: 240)
        let request = try await fixture.sendRequest(deadlineIn: 30)
        XCTAssertEqual(request.sealed.envelope.expiresAt.timeIntervalSince(request.sealed.envelope.sentAt), 330)
        fixture.harness.clock.advance(by: 90)
        // The phone's clock reads 330 seconds after sealing: the request has expired there.
        try await fixture.assertRefused(request.sealed.envelope, at: fixture.phone, .expired)
    }
}
