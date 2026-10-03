import XCTest
@testable import AskKeyBroker
import AskKeyBrokerC
import Darwin

final class BrokerProtocolMethodTests: BrokerProtocolTestCase {
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
}
