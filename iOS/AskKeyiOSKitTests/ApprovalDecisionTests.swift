import AskKeyDevices
import XCTest
@testable import AskKeyiOSKit

/// Deciding on the approver (#314 acceptance 2 and 3).
@MainActor
final class ApprovalDecisionTests: XCTestCase {
    private var world: TestWorld!

    override func setUp() async throws {
        world = TestWorld()
        await world.setUpPhone()
        try await world.pair()
        await world.approveMac()
    }

    override func tearDown() async throws {
        world = nil
    }

    private func receive(offers: ApprovalOffers = .denyOrAllowOnce,
                         timedDuration: UInt64 = 0) async throws -> (SealedApprovalRequest, String) {
        let sealed = try await world.sendRequest(offers: offers, timedDuration: timedDuration)
        await world.model.processInbox()
        return (sealed, try XCTUnwrap(world.card?.id))
    }

    // MARK: Allow and Deny

    func testAllowOnceAsksForFaceIDAndSendsADecisionTheMacVerifies() async throws {
        let phone = try world.phone
        let (sealed, id) = try await receive()
        let prompts = phone.approvalReasons.count
        let authenticating = Box(false)
        phone.duringApprovalPrompt = { [model = world.model] in
            authenticating.value = await model.isAuthenticating
        }
        await world.model.decide(.allowOnce, requestID: id)
        XCTAssertEqual(phone.approvalReasons.count, prompts + 1)
        let reason = try XCTUnwrap(phone.approvalReasons.last)
        for part in ["Codex", TestWorld.macName, "GitHub Token"] {
            XCTAssertTrue(reason.contains("“\(part)”"), "the prompt names \(part): \(reason)")
        }
        XCTAssertTrue(authenticating.value, "the privacy cover stays off while Face ID asks")
        XCTAssertFalse(world.model.isAuthenticating)
        let decisions = try await world.decisions()
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.decision.code, .allowOnce)
        XCTAssertEqual(decisions.first?.decision.requestDigest, sealed.requestDigest)
        XCTAssertEqual(decisions.first?.message.messageID, sealed.request.responseID, "named by the response ID")
        XCTAssertEqual(world.card?.phase(at: world.clock.now()), .waiting(.allowOnce))
    }

    func testDenySendsWithoutFaceID() async throws {
        let phone = try world.phone
        let (_, id) = try await receive()
        let prompts = phone.approvalReasons.count
        await world.model.decide(.deny, requestID: id)
        XCTAssertEqual(phone.approvalReasons.count, prompts, "Deny never asks for Face ID")
        let codes = try await world.decisions().map(\.decision.code)
        XCTAssertEqual(codes, [.deny])
        XCTAssertEqual(world.card?.decision, .deny)
    }

    func testTheTimedAllowanceSignsTheOfferedDuration() async throws {
        let (_, id) = try await receive(offers: .all, timedDuration: 1_800)
        XCTAssertEqual(world.card?.display.offeredCodes, [.deny, .allowOnce, .timedAllowance])
        await world.model.decide(.timedAllowance, requestID: id)
        let first = try await world.decisions().first?.decision
        let decision = try XCTUnwrap(first)
        XCTAssertEqual(decision.code, .timedAllowance)
        XCTAssertEqual(decision.durationCeiling, 1_800)
    }

    func testACancelledOrFailedPromptSendsNothingAndCanBeTriedAgain() async throws {
        let phone = try world.phone
        let (_, id) = try await receive()
        phone.approvalBehavior = .cancel
        await world.model.decide(.allowOnce, requestID: id)
        XCTAssertEqual(world.model.decisionProblems[id], .cancelled)
        XCTAssertTrue(try world.decisionAttempts().isEmpty)
        XCTAssertNil(world.approvalStore.stored.requests.first?.decision)
        phone.approvalBehavior = .fail
        await world.model.decide(.allowOnce, requestID: id)
        XCTAssertEqual(world.model.decisionProblems[id], .failed)
        XCTAssertTrue(try world.decisionAttempts().isEmpty)
        phone.approvalBehavior = .sign
        await world.model.decide(.allowOnce, requestID: id)
        XCTAssertNil(world.model.decisionProblems[id])
        let count = try await world.decisions().count
        XCTAssertEqual(count, 1)
    }

    func testTimeIsCheckedAgainAfterThePrompt() async throws {
        let phone = try world.phone
        let (_, id) = try await receive()
        phone.duringApprovalPrompt = { [clock = world.clock] in clock.advance(by: 301) }
        await world.model.decide(.allowOnce, requestID: id)
        XCTAssertEqual(world.model.decisionProblems[id], .timeUp)
        XCTAssertTrue(try world.decisionAttempts().isEmpty)
    }

    func testTheAccountIsCheckedAgainAfterThePrompt() async throws {
        let phone = try world.phone
        let (_, id) = try await receive()
        phone.duringApprovalPrompt = { [cloud = world.cloud] in cloud.accountState = .available(userRecordName: "_user-b") }
        await world.model.decide(.allowOnce, requestID: id)
        XCTAssertTrue(try world.decisionAttempts().isEmpty)
        XCTAssertTrue(world.model.requests.isEmpty, "the account change drops the stored requests")
    }

    func testAMacWhoseApprovalEndedDuringThePromptGetsNothing() async throws {
        let phone = try world.phone
        let (_, id) = try await receive()
        let macID = world.macIdentity.deviceID.text
        phone.duringApprovalPrompt = { [model = world.model] in await model.stopApproving(macID: macID) }
        await world.model.decide(.allowOnce, requestID: id)
        XCTAssertTrue(try world.decisionAttempts().isEmpty)
        XCTAssertTrue(world.model.requests.isEmpty)
    }

    func testTheAccountIsCheckedBeforeDeny() async throws {
        let (_, id) = try await receive()
        world.cloud.accountState = .noAccount
        await world.model.decide(.deny, requestID: id)
        XCTAssertTrue(try world.decisionAttempts().isEmpty)
        XCTAssertEqual(world.model.accountNotice, .signedOut)
    }

    // MARK: One decision per request

    func testOneDecisionPerRequest() async throws {
        let phone = try world.phone
        let (_, id) = try await receive()
        await world.model.decide(.deny, requestID: id)
        let prompts = phone.approvalReasons.count
        await world.model.decide(.allowOnce, requestID: id)
        XCTAssertEqual(phone.approvalReasons.count, prompts, "the other buttons are disabled")
        XCTAssertEqual(try world.decisionAttempts().count, 1)
        XCTAssertEqual(world.card?.decision, .deny)
    }

    func testTheDecisionIsStoredBeforeItsFirstSendAndResentAfterARelaunch() async throws {
        let (_, id) = try await receive()
        world.cloud.failSends { $0.kind == Int64(MessageKind.approvalDecision.rawValue) }
        await world.model.decide(.allowOnce, requestID: id)
        let stored = try XCTUnwrap(world.approvalStore.stored.requests.first?.decision)
        XCTAssertEqual(stored.decisionCode, .allowOnce)
        XCTAssertEqual(try world.decisionAttempts().map(\.body), [stored.envelope.body], "the stored bytes, before the send")
        XCTAssertEqual(world.card?.phase(at: world.clock.now()), .sending(.allowOnce))

        world.cloud.failSends(where: nil)
        let relaunched = AppModel(environment: world.environment)
        await relaunched.start()
        XCTAssertEqual(relaunched.requests.first?.phase(at: world.clock.now()), .sending(.allowOnce))
        await relaunched.becameActive()
        XCTAssertEqual(relaunched.requests.first?.phase(at: world.clock.now()), .waiting(.allowOnce))
        XCTAssertEqual(try world.decisionAttempts().map(\.body), [stored.envelope.body, stored.envelope.body],
                       "only the stored bytes are ever sent")
        let count = try await world.decisions().count
        XCTAssertEqual(count, 1)
    }

    func testAFailedSendIsRetriedEveryTwoSeconds() async throws {
        let (_, id) = try await receive()
        world.cloud.failSends { $0.kind == Int64(MessageKind.approvalDecision.rawValue) }
        await world.model.decide(.deny, requestID: id)
        XCTAssertEqual(try world.decisionAttempts().count, 1)
        world.clock.advance(by: 1)
        await world.model.processInbox()
        XCTAssertEqual(try world.decisionAttempts().count, 1)
        world.clock.advance(by: 1)
        await world.model.processInbox()
        XCTAssertEqual(try world.decisionAttempts().count, 2)
    }

    func testASavedDecisionIsResentAfterThirtySecondsWithoutAClosedMessage() async throws {
        let (sealed, id) = try await receive()
        await world.model.decide(.deny, requestID: id)
        world.clock.advance(by: 29)
        await world.model.processInbox()
        XCTAssertEqual(try world.decisionAttempts().count, 1)
        world.clock.advance(by: 1)
        await world.model.processInbox()
        let attempts = try world.decisionAttempts()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0].body, attempts[1].body)
        try await world.sendClosed(.applied, code: .deny, for: sealed)
        world.clock.advance(by: 30)
        await world.model.processInbox()
        XCTAssertEqual(try world.decisionAttempts().count, 2, "a closed message ends the resending")
    }

    // MARK: Outcomes

    func testTheClosedOutcomeShowsWhatTheMacApplied() async throws {
        let (sealed, id) = try await receive(offers: .all, timedDuration: 1_800)
        await world.model.decide(.timedAllowance, requestID: id)
        try await world.sendClosed(.applied, code: .timedAllowance, duration: 1_801, for: sealed)
        await world.model.processInbox()
        XCTAssertEqual(world.card?.phase(at: world.clock.now()), .waiting(.timedAllowance),
                       "never longer than this iPhone signed")
        try await world.sendClosed(.applied, code: .allowOnce, for: sealed)
        await world.model.processInbox()
        XCTAssertEqual(world.card?.phase(at: world.clock.now()), .waiting(.timedAllowance), "never another code")
        try await world.sendClosed(.applied, code: .timedAllowance, duration: 1_200, for: sealed)
        await world.model.processInbox()
        XCTAssertEqual(world.card?.phase(at: world.clock.now()), .closed(.allowedTimed(seconds: 1_200)))
    }

    func testAnAppliedOutcomeWithoutADecisionIsRefused() async throws {
        let (sealed, _) = try await receive()
        try await world.sendClosed(.applied, code: .allowOnce, for: sealed)
        await world.model.processInbox()
        XCTAssertEqual(world.card?.phase(at: world.clock.now()), .pending)
    }

    func testEveryOtherOutcome() async throws {
        let outcomes: [(ApprovalClosedOutcome, RequestOutcome)] = [
            (.decidedOnMac, .decidedOnMac), (.decidedOnAnotherApprover, .decidedElsewhere), (.expired, .expired),
            (.cancelled, .cancelled), (.notApplied, .notApplied),
        ]
        for (outcome, expected) in outcomes {
            let sealed = try await world.sendRequest()
            await world.model.processInbox()
            try await world.sendClosed(outcome, for: sealed)
            await world.model.processInbox()
            let card = try XCTUnwrap(world.model.requests.first { $0.id == sealed.sealed.messageID.text })
            XCTAssertEqual(card.phase(at: world.clock.now()), .closed(expected))
        }
    }

    func testWithoutAClosedMessageTheCardSaysToCheckTheMacAndResendingStops() async throws {
        let (_, id) = try await receive()
        await world.model.decide(.allowOnce, requestID: id)
        world.clock.advance(by: 300)
        await world.model.processInbox()
        XCTAssertEqual(world.card?.phase(at: world.clock.now()), .timedOut(decided: .allowOnce))
        XCTAssertEqual(try world.decisionAttempts().count, 1, "no resend once the countdown ended")
    }

    func testAFinishedCardCanBeDismissedAndStaysStored() async throws {
        let (sealed, id) = try await receive()
        world.model.dismissRequest(id: id)
        XCTAssertEqual(world.model.requests.count, 1, "a pending card cannot be dismissed")
        try await world.sendClosed(.decidedOnMac, for: sealed)
        await world.model.processInbox()
        world.model.dismissRequest(id: id)
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertEqual(world.approvalStore.stored.requests.first?.dismissed, true)
    }
}
