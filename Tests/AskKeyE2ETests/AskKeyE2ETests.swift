import XCTest
import Darwin

final class AskKeyE2ETests: E2EBaseCase {
    func testMulticaFirstNetworkFailureRecoversWithoutSecondClick() throws {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "multica-network-recovery"
        app.launch()
        click("unlock-management")
        click("sidebar-agent")
        click("onboarding-review-multica")
        click("onboarding-check-multica")
        let result = app.descendants(matching: .any)["onboarding-completion-multica"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), "One click must recover from the transient route failure")
        XCTAssertTrue(result.isHittable)
        let attemptsURL = runDirectory.appendingPathComponent("read-attempts.txt")
        // The fixture writes in the private runtime directory; the App mirrors
        // its original bytes into the runner's control directory asynchronously.
        let mirrored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let contents = try? String(contentsOf: attemptsURL, encoding: .utf8) else { return false }
            return contents.split(separator: "\n").count >= 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [mirrored], timeout: 5), .completed,
                       "The original fixture attempt ledger must reach the runner")
        let attempts = try String(contentsOf: attemptsURL, encoding: .utf8)
        XCTAssertEqual(attempts.split(separator: "\n").count, 2)
        let failure = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "暂时无法访问 Multica", "暂时无法访问 Multica"
        )).firstMatch
        XCTAssertFalse(failure.exists)
    }

    func testMulticaReviewDoesNotClaimFailureBeforeChecking() throws {
        app.launch()
        click("unlock-management")
        click("sidebar-agent")
        click("onboarding-review-multica")

        XCTAssertTrue(app.buttons["onboarding-check-multica"].waitForExistence(timeout: 8))
        let failure = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "暂时无法访问 Multica", "暂时无法访问 Multica"
        )).firstMatch
        XCTAssertFalse(failure.exists, "Reviewing setup must not invent a failed network check")
        let result = app.descendants(matching: .any)["onboarding-completion-multica"].firstMatch
        XCTAssertFalse(result.exists)

        click("onboarding-check-multica")
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertFalse(failure.exists)
        XCTAssertTrue(result.isHittable)
    }

    func testEnglishCheckShowsCompletionAndDoesNotRunOnEntry() throws {
        app.launchEnvironment["ASKKEY_E2E_LANGUAGE"] = "en"
        app.launch()
        click("unlock-management")
        click("sidebar-agent")
        click("onboarding-review-codex")
        let result = app.descendants(matching: .any)["onboarding-completion-codex"].firstMatch
        XCTAssertFalse(result.exists, "Opening the page must not silently claim a successful check")
        click("onboarding-check-codex")
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let completionText = try XCTUnwrap(result.value as? String)
        XCTAssertTrue(completionText.contains("Complete: Codex is connected"), completionText)
        XCTAssertTrue(result.isHittable)
        XCTAssertTrue(app.buttons["onboarding-check-codex"].label.contains("Check again"))
    }

    func testLaunchAndCheckDisplaysPersistentCompletion() throws {
        app.launch()
        click("unlock-management")
        click("sidebar-agent")
        click("onboarding-review-codex")
        click("onboarding-check-codex")
        let result = app.descendants(matching: .any)["onboarding-completion-codex"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), "Check must visibly complete")
        let completionText = try XCTUnwrap(result.value as? String)
        XCTAssertTrue(completionText.contains("检查完成：Codex 已连接"), completionText)
        XCTAssertTrue(completionText.contains("连接前查询凭证已启用"), completionText)
        XCTAssertTrue(app.buttons["onboarding-check-codex"].label.contains("重新检查"))
        let stable = expectation(description: "Completion remains visible")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { stable.fulfill() }
        wait(for: [stable], timeout: 3)
        XCTAssertTrue(result.exists)
        XCTAssertTrue(result.isHittable, "Completion must remain in the visible viewport")
        XCTAssertNotEqual(app.state, .notRunning)
    }

    func testFailedCheckShowsActionableFeedback() {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "failure"
        app.launch()
        click("unlock-management")
        click("sidebar-agent")
        click("onboarding-review-codex")
        click("onboarding-check-codex")
        let failure = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "本次验证未通过", "本次验证未通过"
        )).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["onboarding-completion-codex"].exists)
        XCTAssertTrue(app.buttons["onboarding-check-codex"].isHittable)
    }

    func testMCPConnectedWithoutDiscoveryDoesNotShowComplete() {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "discovery-missing"
        app.launch()
        click("unlock-management")
        click("sidebar-agent")
        click("onboarding-review-codex")
        click("onboarding-check-codex")
        let discovery = app.staticTexts["onboarding-discovery-codex"]
        XCTAssertTrue(discovery.waitForExistence(timeout: 8))
        let text = (discovery.value as? String) ?? discovery.label
        XCTAssertTrue(text.contains("尚未安装"), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["onboarding-completion-codex"].exists)
        XCTAssertTrue(app.buttons["onboarding-check-codex"].isHittable)
    }

    func testCursorAndGrokConfiguredDiscoveryShowCompletion() throws {
        app.launch()
        click("unlock-management")
        click("sidebar-agent")

        for (client, name) in [("cursor", "Cursor"), ("grok", "Grok CLI")] {
            click("onboarding-review-\(client)")
            click("onboarding-check-\(client)")
            let result = app.descendants(matching: .any)["onboarding-completion-\(client)"].firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 10), "Missing completion for \(name)")
            let completionText = try XCTUnwrap(result.value as? String)
            XCTAssertTrue(completionText.contains("检查完成：\(name) 已连接"), completionText)
            XCTAssertTrue(completionText.contains("新开一个 \(name) 任务"), completionText)
        }
    }

    func testCursorAndGrokMissingDiscoveryDoesNotShowComplete() {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "discovery-missing-local"
        app.launch()
        click("unlock-management")
        click("sidebar-agent")

        for client in ["cursor", "grok"] {
            click("onboarding-review-\(client)")
            click("onboarding-check-\(client)")
            let discovery = app.staticTexts["onboarding-discovery-\(client)"].firstMatch
            XCTAssertTrue(discovery.waitForExistence(timeout: 8), "Missing discovery status for \(client)")
            let text = (discovery.value as? String) ?? discovery.label
            XCTAssertTrue(text.contains("尚未安装"), text)
            XCTAssertFalse(app.descendants(matching: .any)["onboarding-completion-\(client)"].exists)
            XCTAssertTrue(app.buttons["onboarding-check-\(client)"].isHittable)
        }
    }

    func testCancelCheckStopsItsProcessAndAllowsRetry() throws {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "cancel"
        app.launch()
        click("unlock-management")
        click("sidebar-agent")
        click("onboarding-review-codex")
        click("onboarding-check-codex")
        let pidFile = runDirectory.appendingPathComponent("hang.pid")
        let spawned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: pidFile.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [spawned], timeout: 8), .completed)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))
        XCTAssertGreaterThan(pid, 1)
        click("onboarding-cancel-codex")
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in kill(pid, 0) == -1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["onboarding-check-codex"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["onboarding-completion-codex"].exists)
    }

    func testDenyApprovalSettlesRealQueue() throws {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "approval-deny"
        app.launch()
        _ = try waitForEvidence("approval-pending.json")
        try assertRawPending("run-pending.json")
        try assertTargetExecutionCount(0)
        click("approval-deny")
        let result = try assertApprovalResult("denied")
        XCTAssertEqual(result["retryRejected"] as? Bool, true)
        try assertRawState("status-decision.json", equals: "denied")
        try assertRawRejected("run-rejected.json", code: "request_rejected")
        try assertFrozenRunRequests()
        try assertTargetExecutionCount(0)
    }

    func testAllowOnceCannotBeConsumedTwice() throws {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "approval-allow"
        app.launch()
        _ = try waitForEvidence("approval-pending.json")
        try assertRawPending("run-pending.json")
        try assertTargetExecutionCount(0)
        click("approval-allow-once")
        let result = try assertApprovalResult("executed-once")
        XCTAssertEqual(result["firstExitCode"] as? Int, 0)
        XCTAssertEqual(result["replayExitCode"] as? Int, 0)
        XCTAssertEqual(result["ticketState"] as? String, "consumed")
        try assertRawState("status-decision.json", equals: "approved")
        try assertRawState("status-consumed.json", equals: "consumed")
        try assertRawExit("run-executed.json", equals: 0)
        try assertRawExit("run-replay.json", equals: 0)
        try assertFrozenRunRequests()
        let identities = try JSONSerialization.jsonObject(with: Data(contentsOf:
            runDirectory.appendingPathComponent("process-identities.json"))) as? [[String: Any]]
        XCTAssertEqual(identities?.filter { $0["role"] as? String == "helper" }.count, 1,
                       "Pending, decision and retries must use one persistent helper")
        try assertTargetExecutionCount(1)
    }

    func testCancelPendingBrokerApprovalDoesNotExecuteTarget() throws {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "approval-cancel"
        app.launch()
        _ = try waitForEvidence("approval-pending.json")
        try assertRawPending("run-pending.json")
        XCTAssertTrue(app.buttons["approval-deny"].waitForExistence(timeout: 8))
        try assertTargetExecutionCount(0)
        try sendFixtureCommand("cancel")
        let result = try assertApprovalResult("cancelled")
        XCTAssertEqual(result["retryRejected"] as? Bool, true)
        try assertRawState("cancel.json", equals: "cancelled")
        try assertRawRejected("run-rejected.json", code: "request_rejected")
        try assertFrozenRunRequests()
        try assertTargetExecutionCount(0)
    }

    func testDisconnectActiveHelperStopsTargetWithoutReexecution() throws {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "approval-disconnect"
        app.launch()
        _ = try waitForEvidence("approval-pending.json")
        try assertRawPending("run-pending.json")
        click("approval-allow-once")
        let running = try waitForEvidence("target-running.json")
        let pid = try XCTUnwrap((running["pid"] as? NSNumber)?.int32Value)
        let childPID = try XCTUnwrap((running["childPID"] as? NSNumber)?.int32Value)
        XCTAssertGreaterThan(pid, 1)
        XCTAssertGreaterThan(childPID, 1)
        XCTAssertEqual(kill(pid, 0), 0)
        XCTAssertEqual(kill(childPID, 0), 0)
        XCTAssertEqual(getpgid(pid), pid)
        XCTAssertEqual(getpgid(childPID), pid)
        try sendFixtureCommand("disconnect")
        let result = try assertApprovalResult("disconnected")
        XCTAssertEqual(result["targetStopped"] as? Bool, true)
        XCTAssertEqual(result["replayExitCode"] as? Int, 143)
        try assertRawState("status-decision.json", equals: "approved")
        try assertRawExit("run-replay.json", equals: 143)
        try assertFrozenRunRequests()
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(kill(-pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        try assertTargetExecutionCount(1)
    }

    func testRestartInvalidatesPendingBrokerApprovalWithoutExecutingTarget() throws {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "approval-restart"
        app.launch()
        _ = try waitForEvidence("approval-pending.json")
        try assertRawPending("run-pending.json")
        let oldTicket = try rawTicket("run-pending.json")
        XCTAssertTrue(app.buttons["approval-deny"].waitForExistence(timeout: 8))
        try assertTargetExecutionCount(0)
        app.terminate()
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "approval-restart-check"
        app.launch()
        let invalidated = try waitForEvidence("restart-invalidated.json")
        XCTAssertEqual(invalidated["oldTicketInvalid"] as? Bool, true)
        try assertRawRejected("status-old-ticket.json", code: "request_not_found")
        XCTAssertFalse(app.buttons["approval-deny"].exists)
        try assertTargetExecutionCount(0)
        try sendFixtureCommand("restart-retry")
        let result = try waitForEvidence("approval-result.json")
        XCTAssertEqual(result["outcome"] as? String, "restart-requires-new-approval")
        XCTAssertEqual(result["newTicket"] as? Bool, true)
        try assertRawPending("run-new-pending.json")
        let newTicket = try rawTicket("run-new-pending.json")
        XCTAssertNotEqual(newTicket["requestID"] as? String, oldTicket["requestID"] as? String)
        XCTAssertNotEqual(newTicket["capability"] as? String, oldTicket["capability"] as? String)
        try assertFrozenRunRequests()
        try assertTargetExecutionCount(0)
        click("approval-deny")
    }

    @discardableResult
    private func assertApprovalResult(_ expected: String) throws -> [String: Any] {
        let result = try waitForEvidence("approval-result.json")
        XCTAssertEqual(result["outcome"] as? String, expected)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { [app] _, _ in
            app?.buttons["approval-deny"].exists == false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 8), .completed)
        return result
    }

    private func rawBody(_ filename: String, isError: Bool = false) throws -> [String: Any] {
        let envelope = try waitForEvidence(filename)
        XCTAssertEqual(envelope["jsonrpc"] as? String, "2.0")
        XCTAssertNotNil(envelope["id"] as? Int)
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool ?? false, isError)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func rawTicket(_ filename: String) throws -> [String: Any] {
        let body = try rawBody(filename)
        let pending = try XCTUnwrap(body["approvalRequired"] as? [String: Any])
        let tickets = try XCTUnwrap(pending["tickets"] as? [[String: Any]])
        XCTAssertEqual(tickets.count, 1)
        return try XCTUnwrap(tickets.first)
    }

    private func assertRawPending(_ filename: String) throws {
        let ticket = try rawTicket(filename)
        XCTAssertEqual(ticket["state"] as? String, "pending")
        XCTAssertFalse(try XCTUnwrap(ticket["requestID"] as? String).isEmpty)
        XCTAssertFalse(try XCTUnwrap(ticket["capability"] as? String).isEmpty)
    }

    private func assertRawState(_ filename: String, equals expected: String) throws {
        let body = try rawBody(filename)
        let success = try XCTUnwrap(body["success"] as? [String: Any])
        let payload = try XCTUnwrap(success["_0"] as? [String: Any])
        let state = try XCTUnwrap(payload["requestStatus"] as? [String: Any])
        XCTAssertEqual(state["_0"] as? String, expected)
    }

    private func assertRawRejected(_ filename: String, code: String) throws {
        let body = try rawBody(filename, isError: true)
        XCTAssertEqual(body["status"] as? String, "request_rejected")
        XCTAssertEqual(body["brokerCode"] as? String, code)
    }

    private func assertRawExit(_ filename: String, equals expected: Int) throws {
        let body = try rawBody(filename)
        let exited = try XCTUnwrap(body["exited"] as? [String: Any])
        XCTAssertEqual(exited["_0"] as? Int, expected)
    }

    private func assertFrozenRunRequests() throws {
        let frozen = try JSONSerialization.jsonObject(with: Data(contentsOf:
            runDirectory.appendingPathComponent("frozen-run.json")))
        let expected = try JSONSerialization.data(withJSONObject: frozen, options: .sortedKeys)
        let requests = try E2ERequestEvidenceReader.requests(in: runDirectory)
        var runCount = 0
        for envelope in requests {
            let params = try XCTUnwrap(envelope["params"] as? [String: Any])
            guard params["name"] as? String == "run" else { continue }
            runCount += 1
            let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys), expected,
                           "Every retry must preserve operation_id, command, cwd and caller declarations")
        }
        XCTAssertGreaterThanOrEqual(runCount, 2)
    }

}
