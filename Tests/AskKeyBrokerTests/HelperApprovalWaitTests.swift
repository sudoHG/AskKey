import XCTest
@testable import AskKeyBroker
import Darwin

final class HelperApprovalWaitTests: XCTestCase {
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

    func testWaitingHelperStopsOnSIGTERMWithoutSpawningTarget() throws {
        try assertWaitingHelperStopsWithoutSpawningTarget(signalNumber: SIGTERM)
    }

    func testWaitingHelperStopsOnSIGINTWithoutSpawningTarget() throws {
        try assertWaitingHelperStopsWithoutSpawningTarget(signalNumber: SIGINT)
    }

    private func assertWaitingHelperStopsWithoutSpawningTarget(signalNumber: Int32) throws {
        let directory = try makeTemporaryDirectory(prefix: "ak-helper-sigterm")
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let ticket = BrokerApprovalTicket(
            requestID: "sigterm-request",
            capability: "sigterm-capability",
            state: .pending,
            retryCount: 0
        )
        let state = ApprovalWaitTestState(tickets: [ticket], mode: .pending)
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

        let launched = try launchHelper(
            socketPath: socketPath,
            arguments: [
                "run",
                "--wait-for-approval",
                "--credential", "sigterm synthetic credential",
                "--operation-id", "sigterm-operation",
                "--",
                "/usr/bin/true",
            ]
        )
        let observedStatus = state.waitForStatus(timeout: 2)
        XCTAssertTrue(observedStatus, "helper never reached request.status")
        if launched.process.isRunning {
            XCTAssertEqual(Darwin.kill(launched.process.processIdentifier, signalNumber), 0)
        }
        let stopped = waitForExit(launched.process, timeout: 0.5)
        XCTAssertTrue(stopped, "waiting helper must stop on signal \(signalNumber) without requiring SIGKILL")
        if !stopped && launched.process.isRunning {
            _ = Darwin.kill(launched.process.processIdentifier, SIGKILL)
            _ = waitForExit(launched.process, timeout: 1)
        }
        XCTAssertFalse(launched.process.isRunning, "helper remained alive after signal \(signalNumber)/SIGKILL")

        let stdout = launched.output.fileHandleForReading.readDataToEndOfFile()
        let stderr = launched.error.fileHandleForReading.readDataToEndOfFile()
        XCTAssertTrue(stdout.isEmpty, String(decoding: stdout, as: UTF8.self))
        XCTAssertNotEqual(launched.process.terminationStatus, 0)
        XCTAssertEqual(state.resolverCallCount, 1)
        XCTAssertEqual(state.spawnCount, 0)
        XCTAssertEqual(state.recordedRequests.count, 1)
        _ = stderr
    }

    func testSignalBeforeInitialApprovalResponseCannotResumeAfterApproval() throws {
        for signalNumber in [SIGTERM, SIGINT] {
            let directory = try makeTemporaryDirectory(prefix: "ak-wait-early-signal")
            defer { try? FileManager.default.removeItem(at: directory) }
            let socketPath = directory.appendingPathComponent("broker.sock").path
            let marker = directory.appendingPathComponent("target-starts")
            let ticket = BrokerApprovalTicket(
                requestID: "early-signal-request-\(signalNumber)",
                capability: "early-signal-capability-\(signalNumber)",
                state: .pending,
                retryCount: 0
            )
            let state = ApprovalWaitTestState(tickets: [ticket], mode: .approve)
            let fence = ApprovalWaitInitialResponseFence()
            let runtime = BrokerTextRuntime(
                resolveCredentials: { request, _ in
                    state.recordResolverRequest(request)
                    if state.resolverCallCount == 1 {
                        guard fence.pauseInitialResolution() else {
                            throw BrokerTextRuntimeError.invalidRequest
                        }
                        return .approvalRequired([ticket])
                    }
                    return .resolved(
                        [.init(environmentVariable: "ASKKEY_TEST_TOKEN", value: "synthetic")],
                        resolvedRequestCount: 1
                    )
                },
                beforeSystemSpawn: { state.recordSpawn() }
            )
            let server = try startServer(
                socketPath: socketPath,
                state: state,
                runtime: runtime,
                beforeRuntime: { fence.observeControlDescriptor($0.control) }
            )
            defer { server.stop() }
            let launched = try launchHelper(
                socketPath: socketPath,
                arguments: [
                    "run", "--wait-for-approval",
                    "--credential", "early signal synthetic credential",
                    "--operation-id", "early-signal-operation-\(signalNumber)",
                    "--", "/bin/sh", "-c", "printf 'started\\n' >> \"$1\"",
                    "askkey-early-signal-target", marker.path,
                ]
            )
            defer {
                // Release the resolver on every assertion/throw path before
                // stopping the helper or its server; no failed gate can hang.
                fence.releaseInitialResponse()
                if launched.process.isRunning {
                    _ = Darwin.kill(launched.process.processIdentifier, SIGKILL)
                }
                XCTAssertTrue(waitForExit(launched.process, timeout: 1), "helper was not reaped")
            }

            let entered = fence.waitForInitialResolution(timeout: 2)
            XCTAssertTrue(entered, "helper never reached its initial resolver (signal \(signalNumber))")
            guard entered else { continue }
            XCTAssertEqual(Darwin.kill(launched.process.processIdentifier, signalNumber), 0)
            // Observe the real signal-forwarding pipe without reading its byte.
            // A scheduled signal or an EOF alone does not establish this window.
            let signalArrived = fence.waitForForwardedSignal(timeout: 2)
            XCTAssertTrue(signalArrived, "signal was not forwarded before the initial response (\(signalNumber))")
            guard signalArrived else { continue }
            fence.releaseInitialResponse()

            let stopped = waitForExit(launched.process, timeout: 3)
            XCTAssertTrue(stopped, "cancelled helper kept waiting after its initial response (\(signalNumber))")
            if stopped {
                XCTAssertNotEqual(launched.process.terminationStatus, 0,
                                  "cancelled wait resumed an approved target (\(signalNumber))")
            }
            XCTAssertEqual(state.resolverCallCount, 1,
                           "a signal before pending must prevent a second runtime request (\(signalNumber))")
            XCTAssertEqual(state.spawnCount, 0, "cancelled wait reached spawn (\(signalNumber))")
            let targetStarts = FileManager.default.fileExists(atPath: marker.path)
                ? try String(contentsOf: marker, encoding: .utf8).split(whereSeparator: \.isNewline).count
                : 0
            XCTAssertEqual(targetStarts, 0, "real target ran after cancellation (\(signalNumber))")
        }
    }

    func testSignalDuringBlockedApprovedStatusCannotResume() throws {
        for signalNumber in [SIGTERM, SIGINT] {
            let directory = try makeTemporaryDirectory(prefix: "ak-wait-status-signal")
            defer { try? FileManager.default.removeItem(at: directory) }
            let socketPath = directory.appendingPathComponent("broker.sock").path
            let marker = directory.appendingPathComponent("target-starts")
            let ticket = BrokerApprovalTicket(
                requestID: "blocked-status-request-\(signalNumber)",
                capability: "blocked-status-capability-\(signalNumber)",
                state: .pending,
                retryCount: 0
            )
            let state = ApprovalWaitTestState(tickets: [ticket], mode: .approve)
            let statusEntered = DispatchSemaphore(value: 0)
            let statusRelease = DispatchSemaphore(value: 0)
            let runtime = BrokerTextRuntime(
                resolveCredentials: { request, _ in
                    state.recordResolverRequest(request)
                    if state.resolverCallCount == 1 { return .approvalRequired([ticket]) }
                    return .resolved(
                        [.init(environmentVariable: "ASKKEY_TEST_TOKEN", value: "synthetic")],
                        resolvedRequestCount: 1
                    )
                },
                beforeSystemSpawn: { state.recordSpawn() }
            )
            let server = try startServer(
                socketPath: socketPath,
                state: state,
                runtime: runtime,
                beforeStatusResponse: {
                    statusEntered.signal()
                    XCTAssertEqual(statusRelease.wait(timeout: .now() + 5), .success,
                                   "blocked status response was not released")
                }
            )
            defer { server.stop() }
            let launched = try launchHelper(
                socketPath: socketPath,
                arguments: [
                    "run", "--wait-for-approval",
                    "--credential", "blocked status synthetic credential",
                    "--operation-id", "blocked-status-operation-\(signalNumber)",
                    "--", "/bin/sh", "-c", "printf 'started\\n' >> \"$1\"",
                    "askkey-blocked-status-target", marker.path,
                ]
            )
            defer {
                statusRelease.signal()
                if launched.process.isRunning {
                    _ = Darwin.kill(launched.process.processIdentifier, SIGKILL)
                }
                XCTAssertTrue(waitForExit(launched.process, timeout: 1), "helper was not reaped")
            }

            let entered = statusEntered.wait(timeout: .now() + 2) == .success
            XCTAssertTrue(entered, "helper did not reach the blocked approved status response")
            guard entered else { continue }
            XCTAssertEqual(Darwin.kill(launched.process.processIdentifier, signalNumber), 0)
            let stopped = waitForExit(launched.process, timeout: 0.5)
            XCTAssertTrue(stopped, "signal \(signalNumber) did not interrupt blocked request.status")
            guard stopped else { continue }
            statusRelease.signal()

            XCTAssertNotEqual(launched.process.terminationStatus, 0)
            XCTAssertTrue(launched.output.fileHandleForReading.readDataToEndOfFile().isEmpty)
            XCTAssertEqual(state.resolverCallCount, 1)
            XCTAssertEqual(state.spawnCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testWaitingHelperForwardsSignalsAfterApprovedTargetStarts() throws {
        for signalNumber in [SIGTERM, SIGINT] {
            let directory = try makeTemporaryDirectory(prefix: "ak-wait-running-signal")
            defer { try? FileManager.default.removeItem(at: directory) }
            let socketPath = directory.appendingPathComponent("broker.sock").path
            let ready = directory.appendingPathComponent("target-ready")
            let ticket = BrokerApprovalTicket(
                requestID: "running-signal-request-\(signalNumber)",
                capability: "running-signal-capability-\(signalNumber)",
                state: .pending,
                retryCount: 0
            )
            let state = ApprovalWaitTestState(tickets: [ticket], mode: .approve)
            let runtime = BrokerTextRuntime(
                resolveCredentials: { request, _ in
                    state.recordResolverRequest(request)
                    if state.resolverCallCount == 1 { return .approvalRequired([ticket]) }
                    return .resolved(
                        [.init(environmentVariable: "ASKKEY_TEST_TOKEN", value: "synthetic")],
                        resolvedRequestCount: 1
                    )
                },
                beforeSystemSpawn: { state.recordSpawn() }
            )
            let server = try startServer(socketPath: socketPath, state: state, runtime: runtime)
            defer { server.stop() }
            let launched = try launchHelper(
                socketPath: socketPath,
                arguments: [
                    "run", "--wait-for-approval",
                    "--credential", "running signal synthetic credential",
                    "--operation-id", "running-signal-operation-\(signalNumber)",
                    "--", "/bin/sh", "-c",
                    "trap 'printf forwarded; exit 23' INT TERM; : > \"$1\"; while :; do /bin/sleep 0.05; done",
                    "askkey-running-signal-target", ready.path,
                ]
            )
            defer {
                if launched.process.isRunning {
                    _ = Darwin.kill(launched.process.processIdentifier, SIGKILL)
                }
                XCTAssertTrue(waitForExit(launched.process, timeout: 1), "helper was not reaped")
            }

            let readyDeadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            let targetReady = FileManager.default.fileExists(atPath: ready.path)
            XCTAssertTrue(targetReady, "approved target did not install its signal handlers")
            guard targetReady else { continue }
            XCTAssertEqual(Darwin.kill(launched.process.processIdentifier, signalNumber), 0)
            let stopped = waitForExit(launched.process, timeout: 2)
            XCTAssertTrue(stopped, "active target did not receive signal \(signalNumber)")
            guard stopped else { continue }

            let stdout = launched.output.fileHandleForReading.readDataToEndOfFile()
            let stderr = launched.error.fileHandleForReading.readDataToEndOfFile()
            XCTAssertEqual(launched.process.terminationStatus, 23, String(decoding: stderr, as: UTF8.self))
            XCTAssertEqual(String(decoding: stdout, as: UTF8.self), "forwarded")
            XCTAssertEqual(state.resolverCallCount, 2)
            XCTAssertEqual(state.spawnCount, 1)
        }
    }

    func testSignalAfterRuntimeAttachmentPreventsRequestWrite() throws {
        for signalNumber in [SIGTERM, SIGINT] {
            let directory = try makeTemporaryDirectory(prefix: "ak-before-write-signal")
            defer { try? FileManager.default.removeItem(at: directory) }
            let socketPath = directory.appendingPathComponent("broker.sock").path
            let marker = directory.appendingPathComponent("target-starts")
            let state = ApprovalWaitTestState(tickets: [], mode: .legacy)
            let runtime = BrokerTextRuntime(
                resolveCredentials: { request, _ in
                    state.recordResolverRequest(request)
                    return .resolved(
                        [.init(environmentVariable: "ASKKEY_TEST_TOKEN", value: "synthetic")],
                        resolvedRequestCount: 1
                    )
                },
                beforeSystemSpawn: { state.recordSpawn() }
            )
            let server = try startServer(socketPath: socketPath, state: state, runtime: runtime)
            defer { server.stop() }
            let fence = ApprovalWaitInitialResponseFence()
            let client = BrokerSocketClient(socketPath: socketPath, beforeRuntimeRequestWrite: { control, _ in
                fence.observeControlDescriptor(control)
                XCTAssertTrue(fence.pauseInitialResolution(), "pre-write fence was not released")
            })
            let signals = BrokerSignalSession()
            defer { signals.stop() }
            let outcome = ApprovalWaitRunOutcome()
            let finished = DispatchGroup()
            let request = BrokerTextRunRequest(
                operationID: "before-write-signal-\(signalNumber)",
                command: ["/bin/sh", "-c", "printf 'started\\n' >> \"$1\"", "askkey-target", marker.path],
                credentialNames: ["synthetic credential"]
            )
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                outcome.record(Result { try client.run(request, signalSession: signals) })
            }
            defer {
                fence.releaseInitialResponse()
                XCTAssertEqual(finished.wait(timeout: .now() + 3), .success, "runtime caller was not reaped")
            }

            let entered = fence.waitForInitialResolution(timeout: 2)
            XCTAssertTrue(entered, "runtime was not attached before its write fence")
            guard entered else { continue }
            XCTAssertEqual(Darwin.kill(getpid(), signalNumber), 0)
            let arrived = fence.waitForForwardedSignal(timeout: 2)
            XCTAssertTrue(arrived, "signal was not handled before releasing the request write")
            guard arrived else { continue }
            XCTAssertTrue(signals.isCancelled)
            fence.releaseInitialResponse()
            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)

            XCTAssertTrue(outcome.wasCancelled, "a cancelled session wrote its attached request")
            XCTAssertEqual(state.resolverCallCount, 0)
            XCTAssertEqual(state.spawnCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testSlowRuntimePeerDoesNotBlockSignalCancellation() throws {
        for signalNumber in [SIGTERM, SIGINT] {
            try assertSlowRuntimePeerStops(signalNumber: signalNumber)
        }
    }

    func testSlowRuntimePeerReachesFrameDeadlineWithoutCancellation() throws {
        try assertSlowRuntimePeerStops(signalNumber: nil)
    }

    private func assertSlowRuntimePeerStops(signalNumber: Int32?) throws {
        let directory = try makeTemporaryDirectory(prefix: "ak-slow-write")
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let listener = try makeListeningSocket(path: socketPath)
        defer { close(listener) }
        let fence = ApprovalWaitInitialResponseFence()
        let client = BrokerSocketClient(socketPath: socketPath, beforeRuntimeRequestWrite: { control, socket in
            var capacity: Int32 = 1_024
            XCTAssertEqual(setsockopt(socket, SOL_SOCKET, SO_SNDBUF, &capacity,
                                     socklen_t(MemoryLayout.size(ofValue: capacity))), 0)
            fence.observeControlDescriptor(control)
            XCTAssertTrue(fence.pauseInitialResolution(), "slow-write fence was not released")
        })
        let signals = BrokerSignalSession()
        defer { signals.stop() }
        let outcome = ApprovalWaitRunOutcome()
        let finished = DispatchGroup()
        let request = BrokerTextRunRequest(
            operationID: "slow-write-\(signalNumber.map(String.init) ?? "deadline")",
            command: ["/usr/bin/true"] + Array(repeating: String(repeating: "x", count: 3_000), count: 15),
            credentialNames: ["synthetic credential"]
        )
        let frameBytes = try JSONEncoder().encode(BrokerRequest(
            version: BrokerProtocolVersion.current, method: "runtime.run", textRun: request
        )).count + 4
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            outcome.record(Result { try client.run(request, signalSession: signals) })
        }
        defer {
            fence.releaseInitialResponse()
            XCTAssertEqual(finished.wait(timeout: .now() + 3), .success, "slow runtime caller was not reaped")
        }

        let entered = fence.waitForInitialResolution(timeout: 2)
        XCTAssertTrue(entered, "runtime did not reach its slow-write fence")
        guard entered else { return }
        var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pending, 1, 1_000), 1)
        guard pending.revents & Int16(POLLIN) != 0 else { return }
        let peer = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        guard peer >= 0 else { return }
        defer { close(peer) }
        let started = ProcessInfo.processInfo.systemUptime
        fence.releaseInitialResponse()

        // Leave the peer unread. Its partial frame and the constrained sender
        // buffer establish real backpressure for both cancellation and timeout.
        let deadline = started + 1
        var buffered: Int32 = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            buffered = ApprovalWaitInitialResponseFence.availableBytes(descriptor: peer) ?? 0
            if buffered > 4 { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertGreaterThan(buffered, 4, "no body bytes reached the slow peer")
        XCTAssertLessThan(Int(buffered), frameBytes, "the slow peer already received the entire frame")
        guard buffered > 4, Int(buffered) < frameBytes else { return }
        if let signalNumber {
            XCTAssertEqual(Darwin.kill(getpid(), signalNumber), 0)
            XCTAssertEqual(finished.wait(timeout: .now() + 0.5), .success,
                           "a slow peer blocked handling signal \(signalNumber)")
            XCTAssertTrue(signals.isCancelled)
            XCTAssertTrue(outcome.wasCancelled)
        } else {
            XCTAssertEqual(finished.wait(timeout: .now() + BrokerLimits.writeDeadline + 1), .success,
                           "the runtime write required cancellation to stop")
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            XCTAssertGreaterThanOrEqual(elapsed, BrokerLimits.writeDeadline - 0.1)
            XCTAssertLessThan(elapsed, BrokerLimits.writeDeadline + 1)
            XCTAssertFalse(signals.isCancelled)
            XCTAssertEqual(outcome.socketError, .systemError("sendmsg", ETIMEDOUT))
        }
        XCTAssertLessThan(Int(ApprovalWaitInitialResponseFence.availableBytes(descriptor: peer) ?? 0), frameBytes)
    }

    private func makeListeningSocket(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BrokerSocketError.systemError("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw BrokerSocketError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            let error = errno
            close(descriptor)
            throw BrokerSocketError.systemError("listen", error)
        }
        return descriptor
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func startServer(
        socketPath: String,
        state: ApprovalWaitTestState,
        runtime: BrokerTextRuntime,
        beforeRuntime: @escaping @Sendable (BrokerPassedFileDescriptors) -> Void = { _ in },
        beforeStatusResponse: @escaping @Sendable () -> Void = {}
    ) throws -> BrokerSocketServer {
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: .init(
                catalog: { _ in [] },
                requestStatus: { requestID, capability in
                    let result = state.status(requestID: requestID, capability: capability)
                    beforeStatusResponse()
                    return result
                },
                textRun: { request, descriptors, cancellation in
                    beforeRuntime(descriptors)
                    return try runtime.run(
                        request,
                        standardInputFD: descriptors.standardInput,
                        standardOutputFD: descriptors.standardOutput,
                        standardErrorFD: descriptors.standardError,
                        controlFD: descriptors.control,
                        cancellation: cancellation
                    )
                }
            )
        )
        try server.start()
        return server
    }

    private func runHelper(
        socketPath: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> HelperResult {
        let launched = try launchHelper(socketPath: socketPath, arguments: arguments)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while launched.process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if launched.process.isRunning {
            timedOut = true
            launched.process.terminate()
            if !waitForExit(launched.process, timeout: 0.25) {
                _ = Darwin.kill(launched.process.processIdentifier, SIGKILL)
                _ = waitForExit(launched.process, timeout: 1)
            }
        }
        XCTAssertFalse(launched.process.isRunning, "helper process could not be reaped")

        return HelperResult(
            status: launched.process.terminationStatus,
            stdout: launched.output.fileHandleForReading.readDataToEndOfFile(),
            stderr: launched.error.fileHandleForReading.readDataToEndOfFile(),
            timedOut: timedOut
        )
    }

    private func launchHelper(
        socketPath: String,
        arguments: [String]
    ) throws -> LaunchedHelper {
        let process = Process()
        process.executableURL = try helperExecutable()
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ASKKEY_DEBUG_RUN_DIRECTORY")
        environment["ASKKEY_BROKER_SOCKET"] = socketPath
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        try process.run()
        return LaunchedHelper(process: process, output: output, error: error)
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }

    private func helperExecutable() throws -> URL {
        let executable = Bundle(for: HelperApprovalWaitTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("askkey")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return executable
    }
}

private final class ApprovalWaitInitialResponseFence: @unchecked Sendable {
    private let lock = NSLock()
    private var controlDescriptor: Int32 = -1
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func observeControlDescriptor(_ descriptor: Int32) {
        lock.lock(); defer { lock.unlock() }
        controlDescriptor = descriptor
    }

    func pauseInitialResolution() -> Bool {
        entered.signal()
        return release.wait(timeout: .now() + 10) == .success
    }

    func waitForInitialResolution(timeout: TimeInterval) -> Bool {
        entered.wait(timeout: .now() + timeout) == .success
    }

    func releaseInitialResponse() { release.signal() }

    func waitForForwardedSignal(timeout: TimeInterval) -> Bool {
        lock.lock()
        let descriptor = controlDescriptor
        lock.unlock()
        guard descriptor >= 0 else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1_000))
            let result = Darwin.poll(&event, 1, remaining)
            if result < 0, errno == EINTR { continue }
            guard result > 0, event.revents & Int16(POLLIN) != 0 else { return false }
            return (Self.availableBytes(descriptor: descriptor) ?? 0) > 0
        }
        return false
    }

    static func availableBytes(descriptor: Int32) -> Int32? {
        var available: CInt = 0
        // Darwin's FIONREAD is _IOR('f', 127, int). Swift cannot import
        // that sizeof-based macro; encode it using sys/ioccom.h's layout.
        let request = UInt(0x40000000 | (MemoryLayout<CInt>.size << 16) | (0x66 << 8) | 127)
        return Darwin.ioctl(descriptor, request, &available) == 0 ? available : nil
    }
}

private final class ApprovalWaitRunOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<BrokerTextRunResult, Error>?

    func record(_ result: Result<BrokerTextRunResult, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.result = result
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        guard case .failure(let error)? = result else { return false }
        return error is BrokerCancellationError
    }

    var socketError: BrokerSocketError? {
        lock.lock(); defer { lock.unlock() }
        guard case .failure(let error)? = result else { return nil }
        return error as? BrokerSocketError
    }
}

private struct HelperResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

private struct LaunchedHelper {
    let process: Process
    let output: Pipe
    let error: Pipe
}

private final class ApprovalWaitTestState: @unchecked Sendable {
    enum Mode {
        case approve
        case deny
        case legacy
        case pending
        case terminal(BrokerRequestState)
        case missing
    }

    private let lock = NSLock()
    private let tickets: [BrokerApprovalTicket]
    private let mode: Mode
    private var requests: [BrokerTextRunRequest] = []
    private var resolverCalls = 0
    private var spawns = 0
    private var statusCalls: [String: Int] = [:]
    private var allTicketsApproved = false
    private var spawnedBeforeApproval = false
    private let statusObserved = DispatchSemaphore(value: 0)

    init(tickets: [BrokerApprovalTicket], mode: Mode) {
        self.tickets = tickets
        self.mode = mode
    }

    func recordResolverRequest(_ request: BrokerTextRunRequest) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        resolverCalls += 1
    }

    func recordSpawn() {
        lock.lock(); defer { lock.unlock() }
        spawns += 1
        if !allTicketsApproved { spawnedBeforeApproval = true }
    }

    func status(requestID: String, capability: String) -> BrokerRequestState? {
        lock.lock(); defer { lock.unlock() }
        guard tickets.contains(where: { $0.requestID == requestID && $0.capability == capability }) else {
            return nil
        }
        statusObserved.signal()
        statusCalls[capability, default: 0] += 1
        switch mode {
        case .approve:
            guard let index = tickets.firstIndex(where: { $0.capability == capability }) else {
                return nil
            }
            if index == 0 {
                return .approved
            }
            if statusCalls[capability, default: 0] >= 2 {
                allTicketsApproved = true
                return .approved
            }
            return .pending
        case .deny:
            return tickets.first?.capability == capability ? .approved : .denied
        case .legacy:
            return .pending
        case .pending:
            return .pending
        case .terminal(let state):
            return state
        case .missing:
            return nil
        }
    }

    func waitForStatus(timeout: TimeInterval) -> Bool {
        statusObserved.wait(timeout: .now() + timeout) == .success
    }

    var recordedRequests: [BrokerTextRunRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    var resolverCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return resolverCalls
    }

    var spawnCount: Int {
        lock.lock(); defer { lock.unlock() }
        return spawns
    }

    var spawnedBeforeAllTicketsApproved: Bool {
        lock.lock(); defer { lock.unlock() }
        return spawnedBeforeApproval
    }

    func statusCallCount(for capability: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return statusCalls[capability, default: 0]
    }
}
