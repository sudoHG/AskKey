import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

@MainActor
final class ManagementAuthenticationCancellationTests: AskKeyAppTestCase {
    private let presentation = ManagementAuthenticationPresentation(
        reasonKey: ManagementAuthenticationAction.manage.reasonKey, language: "en"
    )

    func testCancelledQueuedAttemptReturnsWithoutLaunchingOrWaitingForTheActivePrompt() async throws {
        let fixture = try AuthenticationChildFixture()
        defer { fixture.remove() }
        let runner = fixture.runner()
        let activeCancellation = ManagementAuthenticationCancellation()
        let active = Task { await runner.authenticate(presentation: presentation, cancellation: activeCancellation) }
        try await fixture.waitForStart()
        let queuedCancellation = ManagementAuthenticationCancellation()
        let queued = Task { await runner.authenticate(presentation: presentation, cancellation: queuedCancellation) }
        queuedCancellation.cancel()
        let queuedResult = await queued.value
        XCTAssertEqual(queuedResult, .cancelled)
        XCTAssertEqual(fixture.events, ["started"])
        activeCancellation.cancel()
        let activeResult = await active.value
        XCTAssertEqual(activeResult, .cancelled)
        await drain(runner)
        XCTAssertEqual(fixture.events, ["started", "cancel", "focus-returned"])
    }

    func testTaskCancellationReleasesQueueAndRejectsLateSuccessfulChildResponse() async throws {
        let fixture = try AuthenticationChildFixture()
        defer { fixture.remove() }
        let runner = fixture.runner()
        let pending = Task { await runner.authenticate(presentation: presentation) }
        try await fixture.waitForStart()
        pending.cancel()
        let result = await pending.value
        XCTAssertEqual(result, .cancelled)
        await drain(runner)
        let next = Task { await runner.authenticate(presentation: presentation) }
        try await fixture.waitForStart(count: 2)
        next.cancel()
        _ = await next.value
        await drain(runner)
        XCTAssertEqual(fixture.events, ["started", "cancel", "focus-returned", "started", "cancel", "focus-returned"])
    }

    func testRequestEndCancelsRunningPromptForDenyExpireAndClose() async throws {
        for end in ["denied", "expired", "closed"] {
            let fixture = try AuthenticationChildFixture()
            defer { fixture.remove() }
            let clock = AuthenticationRequestClock()
            let requests = BrokerApprovalStateMachine(clock: { clock.now })
            let ticket = try requests.submit(ApprovalCardFixtures.request(.read), trustedCredentialDeadline: .none)
            let pendingApproval = try XCTUnwrap(requests.pendingRequests().first)
            let attempt = ApprovalAuthenticationAttempt(pending: pendingApproval, requests: requests, screenUnlocked: { true })
            let cancellation = attempt.cancellation
            let runner = fixture.runner()
            let pending = Task { await runner.authenticate(presentation: presentation, cancellation: cancellation) }
            try await fixture.waitForStart()
            switch end {
            case "denied": _ = try requests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .deny)
            case "expired": clock.advance()
            default: _ = try requests.cancel(requestID: ticket.requestID, capability: ticket.capability)
            }
            let result = await pending.value
            XCTAssertEqual(result, .cancelled)
            await drain(runner)
            XCTAssertEqual(fixture.events, ["started", "cancel", "focus-returned"])
        }
    }

    func testTimeoutRequestsCooperativeCancelAndFocusReturnBeforeForcedTermination() async throws {
        let fixture = try AuthenticationChildFixture()
        defer { fixture.remove() }
        let runner = fixture.runner(timeout: 0.15)
        let result = await runner.authenticate(presentation: presentation)
        XCTAssertEqual(result, .failed, "a timeout must not become a user cancellation or a late success")
        XCTAssertEqual(fixture.events, ["started", "cancel", "focus-returned"])
    }

    func testUnresponsiveChildIsBoundedAfterCancellationGrace() async throws {
        let fixture = try AuthenticationChildFixture(stubborn: true)
        defer { fixture.remove() }
        let started = Date()
        let result = await fixture.runner(timeout: 0.1).authenticate(presentation: presentation)
        XCTAssertEqual(result, .failed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testRunnerAndApprovalBridgePreserveAllThreeOutcomes() async throws {
        for expected in [ManagementAuthenticationOutcome.authenticated, .cancelled, .failed] {
            let fixture = try AuthenticationChildFixture(outcome: expected)
            defer { fixture.remove() }
            let result = await fixture.runner().authenticate(presentation: presentation)
            XCTAssertEqual(result, expected)
            let attempt = ApprovalAuthenticationAttempt(requestEnded: { false })
            XCTAssertEqual(attempt.record(result), expected == .authenticated)
            XCTAssertEqual(attempt.outcome, expected)
        }
    }

    func testChildInvalidatesBeforeFinishingAndIgnoresLateResults() {
        var events: [String] = []
        let completion = ManagementAuthenticationChildCompletion(invalidate: { events.append("invalidate") }) {
            events.append($0.rawValue)
        }
        completion.finish(.cancelled)
        completion.finish(.authenticated)
        completion.finish(.failed)
        XCTAssertEqual(events, ["invalidate", "cancelled"])
    }

    func testChildKeepsCompletedAuthenticationWhenCancellationArrivesLater() {
        var events: [String] = []
        let completion = ManagementAuthenticationChildCompletion(invalidate: { events.append("invalidate") }) {
            events.append($0.rawValue)
        }
        completion.finish(.authenticated)
        completion.finish(.cancelled)
        XCTAssertEqual(events, ["authenticated"])
    }

    private func drain(_ runner: ManagementAuthenticationRunner) async {
        let deadline = Date().addingTimeInterval(2)
        while ManagementAuthenticationRunner.isPromptShowing, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(ManagementAuthenticationRunner.isPromptShowing)
    }

    func testQueuedBlockingApprovalObservesRequestEndBeforeTheActivePromptFinishes() async throws {
        let fixture = try AuthenticationChildFixture()
        defer { fixture.remove() }
        let runner = fixture.runner()
        let active = Task { await runner.authenticate(presentation: presentation) }
        try await fixture.waitForStart()
        let waiting = expectation(description: "queued blocking caller polls its request")
        waiting.expectedFulfillmentCount = 2
        waiting.assertForOverFulfill = false
        let cancellation = ManagementAuthenticationCancellation(requestEnded: { waiting.fulfill(); return false })
        let presentation = presentation
        let queued = Task.detached {
            runner.outcomeBlocking(presentation: presentation, cancellation: cancellation)
        }
        await fulfillment(of: [waiting], timeout: 1)
        cancellation.cancel()
        let result = await queued.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(fixture.events, ["started"])
        active.cancel()
        _ = await active.value
        await drain(runner)
    }
}

private final class AuthenticationRequestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    var now: Date { lock.withLock { date } }
    func advance() { lock.withLock { date = date.addingTimeInterval(600) } }
}

final class AuthenticationChildFixture {
    let directory: URL
    let executable: URL
    private let eventFile: URL

    init(outcome: ManagementAuthenticationOutcome? = nil, stubborn: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyAuth-\(UUID().uuidString)")
        executable = directory.appendingPathComponent("authenticate")
        eventFile = directory.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let body: String
        if let outcome {
            body = "printf '{\"outcome\":\"\(outcome.rawValue)\"}'"
        } else if stubborn {
            body = "trap '' TERM\nexec /bin/sleep 5"
        } else {
            body = """
            printf 'started\n' >> '\(eventFile.path)'
            IFS= read -r command
            printf '%s\n' "$command" >> '\(eventFile.path)'
            printf 'focus-returned\n' >> '\(eventFile.path)'
            printf '{"outcome":"authenticated"}'
            """
        }
        try Data("#!/bin/sh\nIFS= read -r payload\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    var events: [String] {
        ((try? String(contentsOf: eventFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func runner(timeout: TimeInterval = 3) -> ManagementAuthenticationRunner {
        ManagementAuthenticationRunner(
            executableURL: executable, timeout: timeout, terminationGrace: 0.05,
            cancellationGrace: 0.2,
            focus: .init(isActive: { false }, yield: { _ in }, activate: {}, retryDelays: [])
        )
    }

    func waitForStart(count: Int = 1) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if events.filter({ $0 == "started" }).count == count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("authentication child did not start")
        throw CocoaError(.executableRuntimeMismatch)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
