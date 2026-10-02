import XCTest
@testable import AskKeyBroker
#if canImport(Darwin)
import Darwin
#endif

final class RuntimeReceiptBoundsTests: XCTestCase {
    func testInvalidRuntimeRequestsDoNotConsumeReceiptCapacity() throws {
        XCTAssertEqual(BrokerLimits.maximumRuntimeReceiptCount, 65_536)
        let resolverCalls = RuntimeReceiptTestCounter()
        let runtime = BrokerTextRuntime(
            resolveCredentials: { _, _ in
                resolverCalls.increment()
                return .resolved([.init(environmentVariable: "TOKEN", value: "synthetic")])
            },
            receiptCapacity: 2
        )

        let invalidRequests: [(BrokerTextRunRequest, BrokerTextRuntimeError)] = [
            (.init(operationID: "missing-command", command: [], credentialNames: ["TOKEN"]), .missingCommand),
            (.init(operationID: "missing-credentials", command: ["/usr/bin/true"], credentialNames: []), .missingCredentials),
            (.init(operationID: "duplicate-credentials", command: ["/usr/bin/true"], credentialNames: ["TOKEN", "TOKEN"]), .invalidRequest),
            (.init(
                operationID: "invalid-declaration",
                command: ["/usr/bin/true"],
                credentialNames: ["TOKEN"],
                callerName: String(repeating: "x", count: BrokerLimits.maximumFieldBytes + 1)
            ), .invalidRequest),
            (.init(operationID: "invalid-command-field", command: ["/bin/true\0"], credentialNames: ["TOKEN"]), .invalidRequest),
        ]

        for (request, expectedError) in invalidRequests {
            XCTAssertThrowsError(try runtime.run(request)) { error in
                XCTAssertEqual(error as? BrokerTextRuntimeError, expectedError, request.operationID)
            }
        }

        for operationID in ["valid-one", "valid-two"] {
            XCTAssertEqual(
                try runtime.run(.init(operationID: operationID, command: ["/usr/bin/true"], credentialNames: ["TOKEN"])),
                .exited(0)
            )
        }
        XCTAssertThrowsError(
            try runtime.run(.init(operationID: "valid-three", command: ["/usr/bin/true"], credentialNames: ["TOKEN"]))
        ) { error in
            XCTAssertEqual(error as? BrokerProviderError, .resourceExhausted)
        }
        XCTAssertEqual(resolverCalls.value, 2)
    }

    func testSocketCapacityRejectsOnlyNewOperationIDsAndRetainsCompletedReceipts() throws {
        let socketPath = try makeSocketPath()
        let starts = RuntimeReceiptTestCounter()
        let runtime = BrokerTextRuntime(
            resolveCredentials: { _, _ in
                .resolved([.init(environmentVariable: "TOKEN", value: "synthetic")])
            },
            beforeSystemSpawn: { starts.increment() },
            receiptCapacity: 2
        )
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

        let nullFD = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
        guard nullFD >= 0 else { throw BrokerSocketError.systemError("open", errno) }
        defer { Darwin.close(nullFD) }
        let client = BrokerSocketClient(socketPath: socketPath)
        func run(_ request: BrokerTextRunRequest) throws -> BrokerTextRunResult {
            try client.run(
                request,
                standardInputFD: nullFD,
                standardOutputFD: nullFD,
                standardErrorFD: nullFD
            )
        }

        let first = BrokerTextRunRequest(
            operationID: "socket-first",
            command: ["/usr/bin/true"],
            credentialNames: ["TOKEN"]
        )
        let second = BrokerTextRunRequest(
            operationID: "socket-second",
            command: ["/usr/bin/true"],
            credentialNames: ["TOKEN"]
        )
        XCTAssertThrowsError(
            try run(.init(operationID: "socket-invalid", command: [], credentialNames: ["TOKEN"]))
        ) { error in
            XCTAssertEqual(error as? BrokerSocketError, .brokerFailure(.invalidRequest))
        }
        XCTAssertEqual(try run(first), .exited(0))
        XCTAssertEqual(try run(second), .exited(0))
        XCTAssertThrowsError(
            try run(.init(operationID: "socket-third", command: ["/usr/bin/true"], credentialNames: ["TOKEN"]))
        ) { error in
            XCTAssertEqual(error as? BrokerSocketError, .brokerFailure(.resourceExhausted))
        }
        XCTAssertEqual(try run(first), .exited(0))
        XCTAssertEqual(starts.value, 2)
    }

    func testPendingApprovalCanResumeAtCapacityAndConcurrentRetransmissionSpawnsOnce() throws {
        let approvalOperationID = "approval-operation"
        let resolverCalls = RuntimeReceiptTestCounter()
        let starts = RuntimeReceiptTestCounter()
        let resumeEntered = DispatchSemaphore(value: 0)
        let resumeRelease = DispatchSemaphore(value: 0)
        let ticket = BrokerApprovalTicket(
            requestID: "approval-request",
            capability: "approval-capability",
            state: .pending,
            retryCount: 0
        )
        let runtime = BrokerTextRuntime(
            resolveCredentials: { request, _ in
                guard request.operationID == approvalOperationID else {
                    return .resolved([.init(environmentVariable: "TOKEN", value: "synthetic")])
                }
                if resolverCalls.incrementAndGet() == 1 {
                    return .approvalRequired([ticket])
                }
                resumeEntered.signal()
                _ = resumeRelease.wait(timeout: .now() + 2)
                return .resolved([.init(environmentVariable: "TOKEN", value: "synthetic")])
            },
            beforeSystemSpawn: { starts.increment() },
            receiptCapacity: 2
        )
        let approval = BrokerTextRunRequest(
            operationID: approvalOperationID,
            command: ["/usr/bin/true"],
            credentialNames: ["TOKEN"]
        )

        XCTAssertEqual(try runtime.run(approval), .approvalRequired(operationID: approvalOperationID, tickets: [ticket]))
        XCTAssertEqual(
            try runtime.run(.init(operationID: "approval-filler", command: ["/usr/bin/true"], credentialNames: ["TOKEN"])),
            .exited(0)
        )
        XCTAssertThrowsError(
            try runtime.run(.init(operationID: "approval-overflow", command: ["/usr/bin/true"], credentialNames: ["TOKEN"]))
        ) { error in
            XCTAssertEqual(error as? BrokerProviderError, .resourceExhausted)
        }

        let group = DispatchGroup()
        let results = RuntimeReceiptTestResults()
        for label in ["resume-one", "resume-two"] {
            group.enter()
            DispatchQueue.global().async {
                do {
                    let result = try runtime.run(approval)
                    results.record(label, result: result)
                } catch {
                    results.record(label, error: error)
                }
                group.leave()
            }
        }
        XCTAssertEqual(resumeEntered.wait(timeout: .now() + 2), .success)
        resumeRelease.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(results.successes.count, 2)
        XCTAssertTrue(results.errors.isEmpty)
        XCTAssertEqual(resolverCalls.value, 2)
        XCTAssertEqual(starts.value, 2)
        XCTAssertEqual(try runtime.run(approval), .exited(0))
        XCTAssertEqual(resolverCalls.value, 2)
        XCTAssertEqual(starts.value, 2)
    }

    func testConcurrentReceiptReservationsDoNotOverbookOrLeakCapacity() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let starts = RuntimeReceiptTestCounter()
        let runtime = BrokerTextRuntime(
            resolveCredentials: { _, _ in
                .resolved([.init(environmentVariable: "TOKEN", value: "synthetic")])
            },
            beforeSystemSpawn: {
                starts.increment()
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            },
            receiptCapacity: 2
        )
        let nullFD = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
        guard nullFD >= 0 else { throw BrokerSocketError.systemError("open", errno) }
        defer { Darwin.close(nullFD) }

        let outcomes = RuntimeReceiptTestResults()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "runtime-receipt-reservations", attributes: .concurrent)
        for index in 0..<8 {
            let operationID = "concurrent-\(index)"
            group.enter()
            queue.async {
                do {
                    let result = try runtime.run(
                        .init(operationID: operationID, command: ["/usr/bin/true"], credentialNames: ["TOKEN"]),
                        standardInputFD: nullFD,
                        standardOutputFD: nullFD,
                        standardErrorFD: nullFD
                    )
                    outcomes.record(operationID, result: result)
                } catch {
                    outcomes.record(operationID, error: error)
                }
                group.leave()
            }
        }

        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(
            try runtime.run(
                .init(operationID: "concurrent-overflow", command: ["/usr/bin/true"], credentialNames: ["TOKEN"]),
                standardInputFD: nullFD,
                standardOutputFD: nullFD,
                standardErrorFD: nullFD
            )
        ) { error in
            XCTAssertEqual(error as? BrokerProviderError, .resourceExhausted)
        }
        release.signal()
        release.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(outcomes.successes.count, 2)
        XCTAssertEqual(outcomes.resourceExhausted.count, 6)
        XCTAssertTrue(outcomes.errors.isEmpty)
        XCTAssertEqual(starts.value, 2)
        for operationID in outcomes.successes {
            XCTAssertEqual(
                try runtime.run(.init(operationID: operationID, command: ["/usr/bin/true"], credentialNames: ["TOKEN"])),
                .exited(0)
            )
        }
        XCTAssertEqual(starts.value, 2)
        XCTAssertThrowsError(
            try runtime.run(.init(operationID: "concurrent-after-release", command: ["/usr/bin/true"], credentialNames: ["TOKEN"]))
        ) { error in
            XCTAssertEqual(error as? BrokerProviderError, .resourceExhausted)
        }
    }

    func testCompletedReceiptIsReturnedAfterWorkingDirectoryDisappears() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let starts = RuntimeReceiptTestCounter()
        let runtime = BrokerTextRuntime(
            resolveCredentials: { _, _ in
                .resolved([.init(environmentVariable: "TOKEN", value: "synthetic")])
            },
            beforeSystemSpawn: { starts.increment() },
            receiptCapacity: 2
        )
        let request = BrokerTextRunRequest(
            operationID: "mutable-working-directory",
            command: ["/usr/bin/true"],
            credentialNames: ["TOKEN"],
            workingDirectory: directory.path
        )

        XCTAssertEqual(try runtime.run(request), .exited(0))
        try FileManager.default.removeItem(at: directory)
        XCTAssertEqual(try runtime.run(request), .exited(0))
        XCTAssertEqual(starts.value, 1)
    }

    private func makeSocketPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("broker.sock").path
    }
}

private final class RuntimeReceiptTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        _ = incrementAndGet()
    }

    @discardableResult
    func incrementAndGet() -> Int {
        lock.lock()
        count += 1
        let value = count
        lock.unlock()
        return value
    }

    var value: Int {
        lock.lock()
        let result = count
        lock.unlock()
        return result
    }
}

private final class RuntimeReceiptTestResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var successes: [String] = []
    private(set) var resourceExhausted: [String] = []
    private(set) var errors: [String] = []

    func record(_ operationID: String, result: BrokerTextRunResult) {
        lock.lock()
        if case .exited(0) = result {
            successes.append(operationID)
        } else {
            errors.append("\(operationID): \(result)")
        }
        lock.unlock()
    }

    func record(_ operationID: String, error: Error) {
        lock.lock()
        if (error as? BrokerProviderError) == .resourceExhausted {
            resourceExhausted.append(operationID)
        } else {
            errors.append("\(operationID): \(error)")
        }
        lock.unlock()
    }
}
