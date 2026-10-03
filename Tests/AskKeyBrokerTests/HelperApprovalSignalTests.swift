import XCTest
@testable import AskKeyBroker
import Darwin

final class HelperApprovalSignalTests: HelperApprovalWaitTestCase {
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
}
