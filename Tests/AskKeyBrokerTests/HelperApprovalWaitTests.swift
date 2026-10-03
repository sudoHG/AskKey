import XCTest
@testable import AskKeyBroker
import Darwin

final class HelperApprovalWaitTests: HelperApprovalWaitTestCase {
    func testWaitForApprovalRunsExactRequestAfterAllTicketsAreApproved() throws {
        let directory = try makeTemporaryDirectory(prefix: "ak-helper-wait")
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let tickets = [
            BrokerApprovalTicket(
                requestID: "wait-request-a",
                capability: "wait-capability-a",
                state: .pending,
                retryCount: 0
            ),
            BrokerApprovalTicket(
                requestID: "wait-request-b",
                capability: "wait-capability-b",
                state: .pending,
                retryCount: 0
            ),
        ]
        let state = ApprovalWaitTestState(tickets: tickets, mode: .approve)
        let runtime = BrokerTextRuntime(
            resolveCredentials: { request, _ in
                state.recordResolverRequest(request)
                if state.resolverCallCount == 1 {
                    return .approvalRequired(tickets)
                }
                return .resolved(
                    [
                        .init(environmentVariable: "ASKKEY_TEST_TOKEN_A", value: "synthetic-a"),
                        .init(environmentVariable: "ASKKEY_TEST_TOKEN_B", value: "synthetic-b"),
                    ],
                    resolvedRequestCount: 2
                )
            },
            beforeSystemSpawn: {
                state.recordSpawn()
            }
        )
        let server = try startServer(
            socketPath: socketPath,
            state: state,
            runtime: runtime
        )
        addTeardownBlock { server.stop() }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let command = [
            "/bin/sh",
            "-c",
            "if [ \"$ASKKEY_TEST_TOKEN_A\" = synthetic-a ] && [ \"$ASKKEY_TEST_TOKEN_B\" = synthetic-b ]; then printf approved-output; else exit 7; fi",
        ]
        let result = try runHelper(
            socketPath: socketPath,
            arguments: [
                "run",
                "--wait-for-approval",
                "--credential", "first synthetic credential",
                "--credential", "second synthetic credential",
                "--operation-id", "wait-for-approval-operation",
                "--caller-name", "Codex E2E",
                "--caller-purpose", "Verify approval continuation",
                "--",
            ] + command,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, "helper remained in approval wait: \(result.stderrText)")
        XCTAssertEqual(result.status, 0, result.stderrText)
        XCTAssertEqual(result.stdoutText, "approved-output")
        XCTAssertTrue(result.stderrText.lowercased().contains("approval"), result.stderrText)
        XCTAssertFalse(result.stdoutText.contains("approvalRequired"), result.stdoutText)
        XCTAssertFalse(result.stdoutText.contains("wait-for-approval-operation"), result.stdoutText)
        XCTAssertFalse(result.stderrText.contains("synthetic-a"), result.stderrText)
        XCTAssertFalse(result.stderrText.contains("synthetic-b"), result.stderrText)

        XCTAssertEqual(state.resolverCallCount, 2)
        XCTAssertEqual(state.spawnCount, 1)
        XCTAssertFalse(state.spawnedBeforeAllTicketsApproved)
        guard state.recordedRequests.count == 2 else {
            return XCTFail("expected two runtime requests, got \(state.recordedRequests.count)")
        }
        XCTAssertEqual(state.recordedRequests[0], state.recordedRequests[1])
        XCTAssertGreaterThanOrEqual(state.statusCallCount(for: tickets[0].capability), 1)
        XCTAssertGreaterThanOrEqual(state.statusCallCount(for: tickets[1].capability), 2)
    }

    func testWaitForApprovalDeniedWithMultipleTicketsDoesNotSpawn() throws {
        let directory = try makeTemporaryDirectory(prefix: "ak-helper-denied")
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let tickets = [
            BrokerApprovalTicket(
                requestID: "denied-request-a",
                capability: "denied-capability-a",
                state: .pending,
                retryCount: 0
            ),
            BrokerApprovalTicket(
                requestID: "denied-request-b",
                capability: "denied-capability-b",
                state: .pending,
                retryCount: 0
            ),
        ]
        let state = ApprovalWaitTestState(tickets: tickets, mode: .deny)
        let runtime = BrokerTextRuntime(
            resolveCredentials: { request, _ in
                state.recordResolverRequest(request)
                return .approvalRequired(tickets)
            },
            beforeSystemSpawn: {
                state.recordSpawn()
            }
        )
        let server = try startServer(
            socketPath: socketPath,
            state: state,
            runtime: runtime
        )
        addTeardownBlock { server.stop() }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let result = try runHelper(
            socketPath: socketPath,
            arguments: [
                "run",
                "--wait-for-approval",
                "--credential", "first synthetic credential",
                "--credential", "second synthetic credential",
                "--operation-id", "denied-operation",
                "--",
                "/usr/bin/true",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, "helper did not stop after denial: \(result.stderrText)")
        XCTAssertNotEqual(result.status, 0, result.stderrText)
        XCTAssertTrue(result.stdout.isEmpty, result.stdoutText)
        XCTAssertTrue(result.stderrText.lowercased().contains("denied"), result.stderrText)
        XCTAssertEqual(state.resolverCallCount, 1)
        XCTAssertEqual(state.spawnCount, 0)
        guard state.recordedRequests.count == 1 else {
            return XCTFail("expected one runtime request, got \(state.recordedRequests.count)")
        }
        XCTAssertGreaterThanOrEqual(state.statusCallCount(for: tickets[0].capability), 1)
        XCTAssertEqual(state.statusCallCount(for: tickets[1].capability), 1)
    }

    func testRunWithoutWaitFlagKeepsPendingJSONAndDoesNotSpawn() throws {
        let directory = try makeTemporaryDirectory(prefix: "ak-helper-legacy")
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let ticket = BrokerApprovalTicket(
            requestID: "legacy-request",
            capability: "legacy-capability",
            state: .pending,
            retryCount: 0
        )
        let state = ApprovalWaitTestState(tickets: [ticket], mode: .legacy)
        let runtime = BrokerTextRuntime(
            resolveCredentials: { request, _ in
                state.recordResolverRequest(request)
                return .approvalRequired([ticket])
            },
            beforeSystemSpawn: {
                state.recordSpawn()
            }
        )
        let server = try startServer(
            socketPath: socketPath,
            state: state,
            runtime: runtime
        )
        addTeardownBlock { server.stop() }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let result = try runHelper(
            socketPath: socketPath,
            arguments: [
                "run",
                "--credential", "legacy synthetic credential",
                "--operation-id", "legacy-operation",
                "--",
                "/usr/bin/true",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, "legacy helper invocation hung: \(result.stderrText)")
        XCTAssertNotEqual(result.status, 0, result.stderrText)
        let decoded = try JSONDecoder().decode(BrokerTextRunResult.self, from: result.stdout)
        guard case .approvalRequired(let operationID, let returnedTickets) = decoded else {
            return XCTFail("legacy run should return approvalRequired JSON")
        }
        XCTAssertEqual(operationID, "legacy-operation")
        XCTAssertEqual(returnedTickets, [ticket])
        XCTAssertTrue(result.stderrText.lowercased().contains("approval"), result.stderrText)
        XCTAssertEqual(state.resolverCallCount, 1)
        XCTAssertEqual(state.spawnCount, 0)
        guard state.recordedRequests.count == 1 else {
            return XCTFail("expected one runtime request, got \(state.recordedRequests.count)")
        }
    }

    func testWaitForApprovalTerminalStatesNeverResume() throws {
        let terminalStates: [BrokerRequestState?] = [
            .denied,
            .expired,
            .cancelled,
            .outcomeUnknown,
            .consumed,
            .completed,
            nil,
        ]

        for terminalState in terminalStates {
            let directory = try makeTemporaryDirectory(prefix: "ak-helper-terminal")
            let socketPath = directory.appendingPathComponent("broker.sock").path
            let ticket = BrokerApprovalTicket(
                requestID: "terminal-request-\(UUID().uuidString)",
                capability: "terminal-capability-\(UUID().uuidString)",
                state: .pending,
                retryCount: 0
            )
            let state = ApprovalWaitTestState(
                tickets: [ticket],
                mode: terminalState.map(ApprovalWaitTestState.Mode.terminal) ?? .missing
            )
            let runtime = BrokerTextRuntime(
                resolveCredentials: { request, _ in
                    state.recordResolverRequest(request)
                    return .approvalRequired([ticket])
                },
                beforeSystemSpawn: {
                    state.recordSpawn()
                }
            )
            let server = try startServer(
                socketPath: socketPath,
                state: state,
                runtime: runtime
            )
            defer {
                server.stop()
                try? FileManager.default.removeItem(at: directory)
            }

            let result = try runHelper(
                socketPath: socketPath,
                arguments: [
                    "run",
                    "--wait-for-approval",
                    "--credential", "terminal synthetic credential",
                    "--operation-id", "terminal-operation-\(UUID().uuidString)",
                    "--",
                    "/usr/bin/true",
                ],
                timeout: 5
            )

            let stateLabel = terminalState?.rawValue ?? "missing"
            XCTAssertFalse(result.timedOut, "helper did not stop for \(stateLabel): \(result.stderrText)")
            XCTAssertNotEqual(result.status, 0, stateLabel)
            XCTAssertTrue(result.stdout.isEmpty, stateLabel)
            XCTAssertEqual(state.resolverCallCount, 1, stateLabel)
            XCTAssertEqual(state.spawnCount, 0, stateLabel)
            XCTAssertEqual(state.recordedRequests.count, 1, stateLabel)
            XCTAssertGreaterThanOrEqual(state.statusCallCount(for: ticket.capability), 1, stateLabel)
        }
    }
}
