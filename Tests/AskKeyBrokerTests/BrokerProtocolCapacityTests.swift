import XCTest
@testable import AskKeyBroker
import AskKeyBrokerC
import Darwin

final class BrokerProtocolCapacityTests: BrokerProtocolTestCase {
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
}
