import XCTest
@testable import AskKeyBroker
import AskKeyBrokerC
#if canImport(Darwin)
import Darwin
#endif

final class BrokerProtocolTests: XCTestCase {
    func testRuntimeNoResponseIsOutcomeUnknownWithoutRetry() throws {
        let socketPath = try makeSocketPath()
        let accepted = expectation(description: "request accepted")
        try startClosingServer(socketPath: socketPath, accepted: accepted)
        let nullInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        let nullOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))

        XCTAssertEqual(
            try BrokerSocketClient(socketPath: socketPath).run(
                .init(command: ["/usr/bin/true"], credentialNames: ["TOKEN"]),
                standardInputFD: nullInput.fileDescriptor,
                standardOutputFD: nullOutput.fileDescriptor,
                standardErrorFD: nullOutput.fileDescriptor
            ),
            .outcomeUnknown
        )
        wait(for: [accepted], timeout: 2)
    }

    func testSocketDisconnectCancelsRuntimeEvenWhenControlPipeRemainsOpen() throws {
        try assertRuntimeCancellation(.eof)
    }

    func testSocketResetCancelsRuntime() throws {
        try assertRuntimeCancellation(.reset)
    }

    func testProtocolDataDuringRuntimeCancelsWithoutBusyWaiting() throws {
        try assertRuntimeCancellation(.protocolData)
    }

    private enum RuntimeDisconnect { case eof, reset, protocolData }

    private func assertRuntimeCancellation(_ disconnect: RuntimeDisconnect) throws {
        let socketPath = try makeSocketPath()
        let started = expectation(description: "runtime accepted request")
        let returned = expectation(description: "runtime returned")
        let runtime = BrokerTextRuntime(resolveCredentials: { _, _ in
            started.fulfill()
            return .resolved([.init(environmentVariable: "TOKEN", value: "secret")])
        })
        let handler = BrokerRequestHandler(
            catalog: { _ in [] },
            requestStatus: { _, _ in nil },
            textRun: { request, descriptors, cancellation in
                defer { returned.fulfill() }
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
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        addTeardownBlock { server.stop() }
        let clientFD = try connectRaw(to: socketPath)
        var controlPipe: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&controlPipe), 0)
        defer { controlPipe.filter { $0 >= 0 }.forEach { close($0) } }
        let nullInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        let nullOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        let request = BrokerRequest(
            version: BrokerProtocolVersion.current,
            method: "runtime.run",
            textRun: .init(command: ["/bin/sleep", "30"], credentialNames: ["TOKEN"])
        )
        let body = try JSONEncoder().encode(request)
        var frame = Data([
            UInt8((body.count >> 24) & 0xff), UInt8((body.count >> 16) & 0xff),
            UInt8((body.count >> 8) & 0xff), UInt8(body.count & 0xff),
        ])
        frame.append(body)
        let sent = frame.withUnsafeBytes { bytes in
            [nullInput.fileDescriptor, nullOutput.fileDescriptor, nullOutput.fileDescriptor, controlPipe[0]]
                .withUnsafeBufferPointer { descriptors in
                    askkey_send_with_fds(
                        clientFD, bytes.baseAddress, bytes.count,
                        descriptors.baseAddress, descriptors.count
                    )
                }
        }
        XCTAssertEqual(sent, frame.count)
        // Exercise cancellation of an accepted runtime request. Resetting before
        // accept/serve can legitimately reject the socket without calling runtime.
        wait(for: [started], timeout: 2)
        var clientClosed = false
        switch disconnect {
        case .eof:
            close(clientFD)
            clientClosed = true
        case .reset:
            var setting = linger(l_onoff: 1, l_linger: 0)
            XCTAssertEqual(
                setsockopt(clientFD, SOL_SOCKET, SO_LINGER, &setting, socklen_t(MemoryLayout.size(ofValue: setting))),
                0
            )
            close(clientFD)
            clientClosed = true
        case .protocolData:
            var extra: UInt8 = 0xff
            XCTAssertEqual(write(clientFD, &extra, 1), 1)
        }

        wait(for: [returned], timeout: 2)
        if !clientClosed { close(clientFD) }
    }

    func testRuntimePassesCallerDescriptorsToBrokerSpawnWithoutReturningTargetOutput() throws {
        let socketPath = try makeSocketPath()
        let runtime = BrokerTextRuntime(resolveCredentials: { _, _ in
            .resolved([.init(environmentVariable: "TOKEN", value: "fd-secret")])
        })
        let handler = BrokerRequestHandler(
            catalog: { _ in [] },
            requestStatus: { _, _ in nil },
            textRun: { request, descriptors, cancellation in
                try runtime.run(
                    request,
                    standardInputFD: descriptors.standardInput,
                    standardOutputFD: descriptors.standardOutput,
                    standardErrorFD: descriptors.standardError,
                    controlFD: descriptors.control,
                    cancellation: cancellation
                )
            }
        )
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        addTeardownBlock { server.stop() }
        let output = Pipe()
        let nullInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        let nullError = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))

        let result = try BrokerSocketClient(socketPath: socketPath).run(
            .init(
                operationID: "fd-runtime",
                command: ["/bin/sh", "-c", "printf '%s' \"$TOKEN\"; exit 17"],
                credentialNames: ["TOKEN"]
            ),
            standardInputFD: nullInput.fileDescriptor,
            standardOutputFD: output.fileHandleForWriting.fileDescriptor,
            standardErrorFD: nullError.fileDescriptor
        )
        try output.fileHandleForWriting.close()

        XCTAssertEqual(result, .exited(17))
        XCTAssertEqual(
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            "fd-secret"
        )
    }

    private func makeSocketPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("broker.sock").path
    }

    private func startClosingServer(socketPath: String, accepted: XCTestExpectation) throws {
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw BrokerSocketError.systemError("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
            socketPath.withCString { strncpy(destination, $0, capacity - 1) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listenFD, 1) == 0 else {
            close(listenFD)
            throw BrokerSocketError.systemError("bind/listen", errno)
        }
        DispatchQueue.global().async {
            let fd = accept(listenFD, nil, nil)
            if fd >= 0 {
                var byte: UInt8 = 0
                _ = read(fd, &byte, 1)
                close(fd)
            }
            close(listenFD)
            accepted.fulfill()
        }
    }

    func testVersionedHealthAndUnknownMethodsFailClosed() throws {
        let broker = BrokerRequestHandler(catalog: { _ in [] }, requestStatus: { _, _ in nil })

        XCTAssertEqual(
            broker.handle(.init(version: BrokerProtocolVersion.current, method: "health")),
            .success(.health(.init(version: BrokerProtocolVersion.current, status: "ok")))
        )
        XCTAssertEqual(
            broker.handle(.init(version: BrokerProtocolVersion.current + 1, method: "health")),
            .failure(.unsupportedVersion)
        )
        XCTAssertEqual(
            broker.handle(.init(version: BrokerProtocolVersion.current, method: "reveal")),
            .failure(.methodNotAllowed)
        )
    }

    func testPausedCatalogFailsExplicitlyWhileHealthRemainsAvailable() throws {
        let socketPath = try makeSocketPath()
        let handler = BrokerRequestHandler(
            catalog: { _ in throw BrokerProviderError.agentAccessPaused },
            requestStatus: { _, _ in nil }
        )
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        addTeardownBlock { server.stop() }

        let client = BrokerSocketClient(socketPath: socketPath)
        XCTAssertEqual(
            try client.send(.init(version: 1, method: "catalog")),
            .failure(.agentAccessPaused)
        )
        XCTAssertEqual(
            try client.send(.init(version: 1, method: "health")),
            .success(.health(.init(version: 1, status: "ok")))
        )
    }

    func testHealthRoundTripsOverLengthPrefixedUnixSocket() throws {
        let socketPath = try makeSocketPath()
        let handler = BrokerRequestHandler(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        addTeardownBlock { server.stop() }

        let response = try BrokerSocketClient(socketPath: socketPath).send(
            .init(version: BrokerProtocolVersion.current, method: "health")
        )
        XCTAssertEqual(
            response,
            .success(.health(.init(version: BrokerProtocolVersion.current, status: "ok")))
        )
    }

    func testServerDecodeClearsCallerKnownWriteFrame() throws {
        let request = BrokerRequest(
            version: BrokerProtocolVersion.current,
            method: "credential.write.request",
            textWrite: .init(
                operationID: "clear-frame",
                action: .create(name: "Frame Secret", value: "caller-known-frame-value")
            )
        )
        var frame = try JSONEncoder().encode(request)
        let originalCount = frame.count

        XCTAssertEqual(BrokerRequest.decodeClearingFrame(&frame), request)
        XCTAssertEqual(frame.count, originalCount)
        XCTAssertTrue(frame.allSatisfy { $0 == 0 })

        var malformed = Data("caller-known-malformed-frame".utf8)
        XCTAssertNil(BrokerRequest.decodeClearingFrame(&malformed))
        XCTAssertTrue(malformed.allSatisfy { $0 == 0 })
    }

    func testCatalogAndCapabilityBoundRequestStatusAreTheOnlyDataMethods() throws {
        let item = BrokerCatalogItem(
            name: "API Key",
            payloadKind: .text,
            usageInstructions: "Use for builds",
            environmentVariable: "API_KEY",
            expired: false
        )
        let broker = BrokerRequestHandler(
            catalog: { _ in [item] },
            requestStatus: { id, capability in
                id == "request-1" && capability == "unguessable" ? .pending : nil
            }
        )

        XCTAssertEqual(
            broker.handle(.init(version: 1, method: "catalog")),
            .success(.catalog([item]))
        )
        XCTAssertEqual(
            broker.handle(.init(version: 1, method: "request.status", requestID: "request-1", capability: "wrong")),
            .failure(.requestNotFound)
        )
        XCTAssertEqual(
            broker.handle(.init(version: 1, method: "request.status", requestID: "request-1", capability: "unguessable")),
            .success(.requestStatus(.pending))
        )

        for forbidden in [
            "credential.reveal", "permission.list", "permission.set", "group.list",
            "access-record.list", "backup", "restore", "erase", "resume",
            "permanent-delete", "get", "copy", "export", "listProjects",
        ] {
            XCTAssertEqual(
                broker.handle(.init(version: 1, method: forbidden)),
                .failure(.methodNotAllowed),
                forbidden
            )
        }
    }

    func testRequestRegistryBindsStatusAndCancellationToCapabilityAndCapacity() throws {
        let registry = BrokerRequestRegistry()
        try registry.register(requestID: "request-1", capability: "unguessable")
        let handler = BrokerRequestHandler(
            catalog: { _ in [] },
            requestStatus: { registry.status(requestID: $0, capability: $1) },
            cancelRequest: { registry.cancel(requestID: $0, capability: $1) }
        )

        XCTAssertEqual(
            handler.handle(.init(version: 1, method: "request.cancel", requestID: "request-1", capability: "wrong")),
            .failure(.requestNotFound)
        )
        XCTAssertEqual(
            handler.handle(.init(version: 1, method: "request.cancel", requestID: "request-1", capability: "unguessable")),
            .success(.requestStatus(.cancelled))
        )
        XCTAssertFalse(registry.setState(requestID: "request-1", capability: "unguessable", state: .completed))
        XCTAssertEqual(registry.status(requestID: "request-1", capability: "unguessable"), .cancelled)
        XCTAssertEqual(
            handler.handle(.init(version: 1, method: "request.cancel", requestID: "request-1", capability: "unguessable")),
            .success(.requestStatus(.cancelled))
        )

        for index in 1...BrokerLimits.maximumPendingApprovalRequests {
            try registry.register(requestID: "pending-\(index)", capability: "capability-\(index)")
        }
        XCTAssertThrowsError(try registry.register(requestID: "overflow", capability: "overflow")) { error in
            XCTAssertEqual(error as? BrokerRequestRegistryError, .capacityReached)
        }
        for index in 1...BrokerLimits.maximumPendingApprovalRequests {
            XCTAssertTrue(registry.setState(requestID: "pending-\(index)", capability: "capability-\(index)", state: .denied))
        }
        XCTAssertEqual(registry.status(requestID: "pending-1", capability: "capability-1"), .denied)
        XCTAssertNoThrow(try registry.register(requestID: "replacement", capability: "replacement"))
        XCTAssertTrue(registry.setState(requestID: "replacement", capability: "replacement", state: .completed))

        for index in 1...BrokerLimits.maximumRetainedRequestStates {
            let requestID = "retained-\(index)"
            try registry.register(requestID: requestID, capability: requestID)
            XCTAssertTrue(registry.setState(requestID: requestID, capability: requestID, state: .completed))
        }
        XCTAssertNil(registry.status(requestID: "request-1", capability: "unguessable"))
        XCTAssertEqual(
            registry.status(requestID: "retained-\(BrokerLimits.maximumRetainedRequestStates)", capability: "retained-\(BrokerLimits.maximumRetainedRequestStates)"),
            .completed
        )
    }

    func testRequestRegistryCancelsEveryPendingRequestWithoutChangingTerminalState() throws {
        let registry = BrokerRequestRegistry()
        try registry.register(requestID: "pending-1", capability: "cap-1")
        try registry.register(requestID: "pending-2", capability: "cap-2")
        try registry.register(requestID: "completed", capability: "cap-3")
        XCTAssertTrue(registry.setState(requestID: "completed", capability: "cap-3", state: .completed))

        XCTAssertEqual(registry.cancelAllPending(), 2)
        XCTAssertEqual(registry.status(requestID: "pending-1", capability: "cap-1"), .cancelled)
        XCTAssertEqual(registry.status(requestID: "pending-2", capability: "cap-2"), .cancelled)
        XCTAssertEqual(registry.status(requestID: "completed", capability: "cap-3"), .completed)
        XCTAssertEqual(registry.cancelAllPending(), 0)
    }

    func testConcurrentPauseAndRegistrationCannotLeaveAPendingRequest() throws {
        for index in 0..<100 {
            let registry = BrokerRequestRegistry()
            let requestID = "request-\(index)"
            let capability = "capability-\(index)"
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "broker-pause-race", attributes: .concurrent)
            group.enter()
            queue.async {
                _ = try? registry.register(requestID: requestID, capability: capability)
                group.leave()
            }
            group.enter()
            queue.async {
                registry.pauseAndCancelAll()
                group.leave()
            }
            XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
            let state = registry.status(requestID: requestID, capability: capability)
            XCTAssertTrue(state == nil || state == .cancelled, "round \(index): \(String(describing: state))")
            XCTAssertThrowsError(
                try registry.register(requestID: "after-\(index)", capability: capability)
            ) { error in
                XCTAssertEqual(error as? BrokerRequestRegistryError, .agentAccessPaused)
            }
        }
    }

    func testOversizedTruncatedAndSlowFramesFailClosed() throws {
        let socketPath = try makeSocketPath()
        let handler = BrokerRequestHandler(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        addTeardownBlock { server.stop() }

        let oversized = try connectRaw(to: socketPath)
        defer { close(oversized) }
        var tooLarge = UInt32(BrokerLimits.maximumFrameBytes + 1).bigEndian
        XCTAssertEqual(write(oversized, &tooLarge, 4), 4)
        XCTAssertEqual(try readResponse(from: oversized), .failure(.resourceExhausted))

        let truncated = try connectRaw(to: socketPath)
        defer { close(truncated) }
        var ten = UInt32(10).bigEndian
        XCTAssertEqual(write(truncated, &ten, 4), 4)
        XCTAssertEqual(write(truncated, "{}", 2), 2)
        XCTAssertEqual(shutdown(truncated, SHUT_WR), 0)
        XCTAssertEqual(try readResponse(from: truncated), .failure(.deadlineExceeded))

        let slow = try connectRaw(to: socketPath)
        defer { close(slow) }
        var oneHeaderByte: UInt8 = 0
        XCTAssertEqual(write(slow, &oneHeaderByte, 1), 1)
        XCTAssertEqual(try readResponse(from: slow), .failure(.deadlineExceeded))

        let drip = try connectRaw(to: socketPath)
        defer { close(drip) }
        var dripByte: UInt8 = 0
        XCTAssertEqual(write(drip, &dripByte, 1), 1)
        usleep(700_000)
        XCTAssertEqual(write(drip, &dripByte, 1), 1)
        usleep(700_000)
        XCTAssertEqual(write(drip, &dripByte, 1), 1)
        XCTAssertEqual(try readResponse(from: drip), .failure(.deadlineExceeded))
    }

    func testPartialPayloadEOFTimeoutAndReadErrorClearBytesAlreadyRead() throws {
        let socketPath = try makeSocketPath()
        let cleared = FailedReadBufferRecorder()
        let handler = BrokerRequestHandler(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: handler,
            failedReadBufferCleared: { cleared.record($0) }
        )
        try server.start()
        addTeardownBlock { server.stop() }
        let partial = Data("caller-known-partial-value".utf8)
        let declaredLength = partial.count + 16

        let eof = try connectRaw(to: socketPath)
        defer { close(eof) }
        try writePartialFrame(fd: eof, declaredLength: declaredLength, partial: partial)
        XCTAssertEqual(shutdown(eof, SHUT_WR), 0)
        XCTAssertEqual(try readResponse(from: eof), .failure(.deadlineExceeded))
        try assertClearedPartial(
            try cleared.next(),
            expectedBytesRead: partial.count,
            expectedFailure: .endOfFile
        )

        let timeout = try connectRaw(to: socketPath)
        defer { close(timeout) }
        try writePartialFrame(fd: timeout, declaredLength: declaredLength, partial: partial)
        XCTAssertEqual(try readResponse(from: timeout), .failure(.deadlineExceeded))
        try assertClearedPartial(
            try cleared.next(),
            expectedBytesRead: partial.count,
            expectedFailure: .deadline
        )

        BrokerSocketServer.exercisePartialReadErrorForTesting(
            partial: partial,
            declaredLength: declaredLength,
            errorCode: EIO,
            failedReadBufferCleared: { cleared.record($0) }
        )
        let readError = try cleared.next()
        try assertClearedPartial(
            readError,
            expectedBytesRead: partial.count,
            expectedFailure: .readError(EIO)
        )
    }

    func testOversizedFieldsAndResponsesFailClosed() throws {
        let oversizedField = String(repeating: "x", count: BrokerLimits.maximumFieldBytes + 1)
        let handler = BrokerRequestHandler(
            catalog: { _ in
                (0..<BrokerLimits.maximumResponseBytes).map {
                    .init(name: "credential-\($0)", payloadKind: .text, usageInstructions: "", environmentVariable: nil, expired: false)
                }
            },
            requestStatus: { _, _ in nil }
        )
        XCTAssertEqual(
            handler.handle(.init(version: 1, method: "request.status", requestID: oversizedField, capability: "c")),
            .failure(.invalidRequest)
        )

        let socketPath = try makeSocketPath()
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        addTeardownBlock { server.stop() }
        XCTAssertEqual(
            try BrokerSocketClient(socketPath: socketPath).send(.init(version: 1, method: "catalog")),
            .failure(.responseTooLarge)
        )
    }

    func testConnectionLimitRejectsExcessClients() throws {
        let socketPath = try makeSocketPath()
        let handler = BrokerRequestHandler(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        addTeardownBlock { server.stop() }

        var held: [Int32] = []
        defer { held.forEach { close($0) } }
        for _ in 0..<BrokerLimits.maximumConnections {
            let fd = try connectRaw(to: socketPath)
            var partialHeader: UInt8 = 0
            XCTAssertEqual(write(fd, &partialHeader, 1), 1)
            held.append(fd)
        }
        let excess = try connectRaw(to: socketPath)
        defer { close(excess) }
        XCTAssertEqual(try readResponse(from: excess), .failure(.resourceExhausted))
    }

    func testGlobalConcurrentRequestLimitRejectsExcessWork() throws {
        let socketPath = try makeSocketPath()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let handler = BrokerRequestHandler(
            catalog: { _ in
                entered.signal()
                release.wait()
                return []
            },
            requestStatus: { _, _ in nil }
        )
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        addTeardownBlock { server.stop() }

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "broker-limit-clients", attributes: .concurrent)
        for _ in 0..<BrokerLimits.maximumConcurrentRequests {
            group.enter()
            queue.async {
                _ = try? BrokerSocketClient(socketPath: socketPath).send(.init(version: 1, method: "catalog"))
                group.leave()
            }
        }
        for _ in 0..<BrokerLimits.maximumConcurrentRequests {
            XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        }

        XCTAssertEqual(
            try BrokerSocketClient(socketPath: socketPath).send(.init(version: 1, method: "catalog")),
            .failure(.resourceExhausted)
        )
        for _ in 0..<BrokerLimits.maximumConcurrentRequests { release.signal() }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
    }

    func testRequestExecutionHasAHardDeadline() throws {
        let socketPath = try makeSocketPath()
        let handler = BrokerRequestHandler(
            catalog: { cancellation in
                cancellation.waitUntilCancelled()
                throw BrokerCancellationError.cancelled
            },
            requestStatus: { _, _ in nil }
        )
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        defer { server.stop() }

        XCTAssertEqual(
            try BrokerSocketClient(socketPath: socketPath).send(.init(version: 1, method: "catalog")),
            .failure(.deadlineExceeded)
        )
    }

    func testTimedOutAndDisconnectedWriteSubmissionsAreCancelled() throws {
        let writeRequest = AgentTextWriteRequest(
            operationID: "write-disconnect",
            action: .create(name: "Credential", value: "caller-known")
        )

        let timeoutPath = try makeSocketPath()
        let timeoutCancelled = DispatchSemaphore(value: 0)
        let timeoutHandler = BrokerRequestHandler(
            catalog: { _ in [] },
            requestStatus: { _, _ in nil },
            submitTextWrite: { request, cancellation in
                cancellation.waitUntilCancelled()
                return .submitted(.init(
                    operationID: request.operationID,
                    requestID: "timeout-request",
                    capability: "timeout-capability",
                    state: .pending,
                    retryCount: 0
                ))
            },
            cancelTextWrite: { _, requestID, capability in
                if requestID == "timeout-request", capability == "timeout-capability" {
                    timeoutCancelled.signal()
                }
                return .cancelled
            }
        )
        let timeoutServer = BrokerSocketServer(socketPath: timeoutPath, handler: timeoutHandler)
        try timeoutServer.start()
        defer { timeoutServer.stop() }
        XCTAssertEqual(
            try BrokerSocketClient(socketPath: timeoutPath).send(
                .init(version: 1, method: "credential.write.request", textWrite: writeRequest)
            ),
            .failure(.deadlineExceeded)
        )
        XCTAssertEqual(timeoutCancelled.wait(timeout: .now() + 2), .success)

        let disconnectPath = try makeSocketPath()
        let disconnectSubmissionEntered = DispatchSemaphore(value: 0)
        let releaseDisconnectSubmission = DispatchSemaphore(value: 0)
        let disconnectCancelled = DispatchSemaphore(value: 0)
        let disconnectHandler = BrokerRequestHandler(
            catalog: { _ in [] },
            requestStatus: { _, _ in nil },
            submitTextWrite: { request, _ in
                disconnectSubmissionEntered.signal()
                releaseDisconnectSubmission.wait()
                return .submitted(.init(
                    operationID: request.operationID,
                    requestID: "disconnect-request",
                    capability: "disconnect-capability",
                    state: .pending,
                    retryCount: 0
                ))
            },
            cancelTextWrite: { _, requestID, capability in
                if requestID == "disconnect-request", capability == "disconnect-capability" {
                    disconnectCancelled.signal()
                }
                return .cancelled
            }
        )
        let disconnectServer = BrokerSocketServer(socketPath: disconnectPath, handler: disconnectHandler)
        try disconnectServer.start()
        defer { disconnectServer.stop() }
        let fd = try connectRaw(to: disconnectPath)
        let encoded = try JSONEncoder().encode(
            BrokerRequest(version: 1, method: "credential.write.request", textWrite: writeRequest)
        )
        var frame = Data()
        var length = UInt32(encoded.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(encoded)
        XCTAssertEqual(frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, frame.count)
        guard disconnectSubmissionEntered.wait(timeout: .now() + 2) == .success else {
            releaseDisconnectSubmission.signal()
            close(fd)
            XCTFail("server must receive the complete submission before the peer resets")
            return
        }
        var lingerReset = linger(l_onoff: 1, l_linger: 0)
        XCTAssertEqual(
            setsockopt(fd, SOL_SOCKET, SO_LINGER, &lingerReset, socklen_t(MemoryLayout<linger>.size)),
            0
        )
        close(fd)
        releaseDisconnectSubmission.signal()
        XCTAssertEqual(disconnectCancelled.wait(timeout: .now() + 2), .success)
    }

    func testEightTimedOutCatalogsDoNotExhaustHealth() throws {
        let socketPath = try makeSocketPath()
        let entered = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        let handler = BrokerRequestHandler(
            catalog: { cancellation in
                entered.signal()
                defer { exited.signal() }
                cancellation.waitUntilCancelled()
                throw BrokerCancellationError.cancelled
            },
            requestStatus: { _, _ in nil }
        )
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        defer { server.stop() }

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "timed-out-catalogs", attributes: .concurrent)
        for _ in 0..<BrokerLimits.maximumConcurrentRequests {
            group.enter()
            queue.async {
                _ = try? BrokerSocketClient(socketPath: socketPath).send(.init(version: 1, method: "catalog"))
                group.leave()
            }
        }
        for _ in 0..<BrokerLimits.maximumConcurrentRequests {
            XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        }
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        for _ in 0..<BrokerLimits.maximumConcurrentRequests {
            XCTAssertEqual(exited.wait(timeout: .now() + 1), .success)
        }

        XCTAssertEqual(
            try BrokerSocketClient(socketPath: socketPath).send(.init(version: 1, method: "health")),
            .success(.health(.init(version: BrokerProtocolVersion.current, status: "ok")))
        )
    }

    private func connectRaw(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerSocketError.systemError("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); throw BrokerSocketError.pathTooLong }
        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
            path.withCString { strncpy(destination, $0, capacity - 1) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); throw BrokerSocketError.notRunning }
        return fd
    }

    private func readResponse(from fd: Int32) throws -> BrokerResponse {
        let header = try readExactly(4, from: fd)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let body = try readExactly(Int(length), from: fd)
        return try JSONDecoder().decode(BrokerResponse.self, from: body)
    }

    private func writePartialFrame(fd: Int32, declaredLength: Int, partial: Data) throws {
        var length = UInt32(declaredLength).bigEndian
        XCTAssertEqual(write(fd, &length, 4), 4)
        XCTAssertEqual(partial.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, partial.count)
    }

    private func assertClearedPartial(
        _ cleared: BrokerClearedReadBuffer,
        expectedBytesRead: Int,
        expectedFailure: BrokerClearedReadFailure? = nil
    ) throws {
        XCTAssertEqual(cleared.bytesRead, expectedBytesRead)
        XCTAssertGreaterThan(cleared.bytesRead, 0)
        XCTAssertTrue(cleared.buffer.allSatisfy { $0 == 0 })
        if let expectedFailure { XCTAssertEqual(cleared.failure, expectedFailure) }
    }

    private func readExactly(_ count: Int, from fd: Int32) throws -> Data {
        var result = Data()
        while result.count < count {
            var buffer = [UInt8](repeating: 0, count: count - result.count)
            let amount = read(fd, &buffer, buffer.count)
            guard amount > 0 else { throw BrokerSocketError.noResponse }
            result.append(contentsOf: buffer.prefix(amount))
        }
        return result
    }
}

private final class FailedReadBufferRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [BrokerClearedReadBuffer] = []

    func record(_ value: BrokerClearedReadBuffer) {
        condition.lock()
        values.append(value)
        condition.signal()
        condition.unlock()
    }

    func next() throws -> BrokerClearedReadBuffer {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(BrokerLimits.readDeadline + 2)
        while values.isEmpty, condition.wait(until: deadline) {}
        guard !values.isEmpty else { throw BrokerSocketError.noResponse }
        return values.removeFirst()
    }
}
