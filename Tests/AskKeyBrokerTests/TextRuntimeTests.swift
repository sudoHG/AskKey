import XCTest
@testable import AskKeyBroker
#if canImport(Darwin)
import Darwin
#endif

final class TextRuntimeTests: XCTestCase {
    func testCompletedRequestsDoNotExhaustCapacityOrForgetUnknownRuntimeIdentity() throws {
        let ledger = BrokerRuntimeOperations()
        var executions = 0
        let first = BrokerTextRunRequest(operationID: "first", command: ["/usr/bin/true"], credentialNames: ["TOKEN"])
        XCTAssertEqual(try ledger.perform(first, cancellation: .init()) {
            executions += 1
            return .outcomeUnknown
        }, .outcomeUnknown)
        for index in 1..<(BrokerLimits.maximumRetainedRequestStates * 3) {
            let request = BrokerTextRunRequest(operationID: "operation-\(index)", command: ["/usr/bin/true"], credentialNames: ["TOKEN"])
            _ = try ledger.perform(request, cancellation: .init()) { .exited(0) }
        }
        let overflow = BrokerTextRunRequest(operationID: "overflow", command: ["/usr/bin/true"], credentialNames: ["TOKEN"])
        XCTAssertEqual(try ledger.perform(overflow, cancellation: .init()) {
            return .exited(0)
        }, .exited(0))
        XCTAssertEqual(try ledger.perform(first, cancellation: .init()) {
            executions += 1
            return .exited(0)
        }, .outcomeUnknown)
        XCTAssertEqual(executions, 1)
        XCTAssertThrowsError(try ledger.perform(.init(operationID: first.operationID, command: ["/usr/bin/false"], credentialNames: ["TOKEN"]), cancellation: .init()) { .exited(0) }) {
            XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch)
        }
    }

    func testConcurrentRuntimeAdmissionIsBoundedWithoutRetiringCompletedReceipts() throws {
        let ledger = BrokerRuntimeOperations()
        func nest(_ depth: Int) throws -> BrokerTextRunResult {
            try ledger.perform(.init(operationID: "active-\(depth)", command: ["/usr/bin/true"], credentialNames: ["TOKEN"]), cancellation: .init()) {
                if depth == BrokerLimits.maximumConcurrentRequests - 1 {
                    XCTAssertThrowsError(try ledger.perform(.init(operationID: "capacity-overflow", command: ["/usr/bin/true"], credentialNames: ["TOKEN"]), cancellation: .init()) {
                        XCTFail("An over-capacity operation must not start")
                        return .exited(0)
                    }) { XCTAssertEqual($0 as? BrokerProviderError, .resourceExhausted) }
                    return .exited(0)
                }
                return try nest(depth + 1)
            }
        }
        XCTAssertEqual(try nest(0), .exited(0))
        XCTAssertEqual(try ledger.perform(.init(operationID: "capacity-overflow", command: ["/usr/bin/true"], credentialNames: ["TOKEN"]), cancellation: .init()) { .exited(0) }, .exited(0))
    }

    func testCompletedRuntimeRetransmissionReturnsOriginalResultWithoutAnotherProcess() throws {
        let starts = LockedCounter()
        let runtime = BrokerTextRuntime(
            resolveCredentials: { _, _ in .resolved([.init(environmentVariable: "TOKEN", value: "synthetic")]) },
            beforeSystemSpawn: { starts.increment() }
        )
        let request = BrokerTextRunRequest(operationID: "same-operation", command: ["/usr/bin/true"], credentialNames: ["TOKEN"])
        XCTAssertEqual(try runtime.run(request), .exited(0))
        XCTAssertEqual(try runtime.run(request), .exited(0))
        XCTAssertEqual(starts.value, 1)
        XCTAssertThrowsError(try runtime.run(.init(operationID: request.operationID, command: ["/usr/bin/false"], credentialNames: ["TOKEN"]))) {
            XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch)
        }
        XCTAssertEqual(starts.value, 1)
    }

    func testUnknownRuntimeOutcomeIsRetainedAndNeverAutomaticallyRetried() throws {
        let starts = LockedCounter()
        let runtime = BrokerTextRuntime(
            resolveCredentials: { _, _ in .resolved([.init(environmentVariable: "TOKEN", value: "synthetic")]) },
            beforeSystemSpawn: { starts.increment() },
            afterSpawn: { throw BrokerTextRuntimeError.spawnFailed }
        )
        let request = BrokerTextRunRequest(operationID: "unknown-operation", command: ["/bin/sleep", "1"], credentialNames: ["TOKEN"])
        XCTAssertEqual(try runtime.run(request), .outcomeUnknown)
        XCTAssertEqual(try runtime.run(request), .outcomeUnknown)
        XCTAssertEqual(starts.value, 1)
    }

    func testRunRequiresACommandAndExplicitCredentials() throws {
        let runtime = BrokerTextRuntime(resolveCredentials: { _, _ in .resolved([]) })

        XCTAssertThrowsError(try runtime.run(.init(command: [], credentialNames: ["TOKEN"]))) {
            XCTAssertEqual($0 as? BrokerTextRuntimeError, .missingCommand)
        }
        XCTAssertThrowsError(try runtime.run(.init(command: ["/usr/bin/true"], credentialNames: []))) {
            XCTAssertEqual($0 as? BrokerTextRuntimeError, .missingCredentials)
        }
        XCTAssertThrowsError(
            try runtime.run(.init(command: ["/usr/bin/true"], credentialNames: ["TOKEN"]))
        ) {
            XCTAssertEqual($0 as? BrokerTextRuntimeError, .invalidCredentialMapping)
        }
    }

    func testApprovalResponseReturnsTheOperationIDNeededForRetry() throws {
        let ticket = BrokerApprovalTicket(
            requestID: "request",
            capability: "capability",
            state: .pending,
            retryCount: 0
        )
        let runtime = BrokerTextRuntime(resolveCredentials: { _, _ in
            .approvalRequired([ticket])
        })

        XCTAssertEqual(
            try runtime.run(.init(
                operationID: "stable-operation",
                command: ["/usr/bin/true"],
                credentialNames: ["TOKEN"]
            )),
            .approvalRequired(operationID: "stable-operation", tickets: [ticket])
        )
    }

    func testRunInjectsOnlyResolvedMappingsAndConnectsCallerFileDescriptors() throws {
        let stdout = Pipe()
        let stderr = Pipe()
        let nullInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        let runtime = BrokerTextRuntime(resolveCredentials: { request, _ in
            XCTAssertEqual(request.credentialNames, ["DEPLOY_TOKEN"])
            return .resolved([.init(environmentVariable: "TOKEN", value: "selected-secret")])
        })
        let request = BrokerTextRunRequest(
            command: ["/bin/sh", "-c", "printf '%s|%s|%s' \"$TOKEN\" \"${UNSELECTED-unset}\" \"$PWD\"; printf error >&2; exit 23"],
            credentialNames: ["DEPLOY_TOKEN"],
            workingDirectory: FileManager.default.temporaryDirectory.path,
            inheritedEnvironment: ["PATH": "/usr/bin:/bin", "UNSELECTED": "caller-value"]
        )

        let result = try runtime.run(
            request,
            standardInputFD: nullInput.fileDescriptor,
            standardOutputFD: stdout.fileHandleForWriting.fileDescriptor,
            standardErrorFD: stderr.fileHandleForWriting.fileDescriptor
        )
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()

        XCTAssertEqual(result, .exited(23))
        let fields = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(Array(fields.prefix(2)), ["selected-secret", "unset"])
        XCTAssertEqual(
            URL(fileURLWithPath: fields[2]).resolvingSymlinksInPath(),
            FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        )
        XCTAssertEqual(
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            "error"
        )
    }

    func testOneCredentialCanResolveToMultipleAtomicRuntimeMappings() throws {
        let stdout = Pipe()
        let runtime = BrokerTextRuntime(resolveCredentials: { request, _ in
            XCTAssertEqual(request.credentialNames, ["Production API"])
            return .resolved([
                .init(environmentVariable: "API_TOKEN", value: "token-value"),
                .init(environmentVariable: "API_ENDPOINT", value: "https://api.example.com"),
            ])
        })

        let result = try runtime.run(
            .init(
                command: ["/bin/sh", "-c", "printf '%s|%s' \"$API_TOKEN\" \"$API_ENDPOINT\""],
                credentialNames: ["Production API"]
            ),
            standardOutputFD: stdout.fileHandleForWriting.fileDescriptor
        )
        try stdout.fileHandleForWriting.close()

        XCTAssertEqual(result, .exited(0))
        XCTAssertEqual(
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            "token-value|https://api.example.com"
        )
    }

    func testMultipleCredentialRequestRejectsAResolverThatResolvedOnlyOneRequest() {
        let runtime = BrokerTextRuntime(resolveCredentials: { _, _ in
            .resolved([.init(environmentVariable: "FIRST", value: "secret")])
        })

        XCTAssertThrowsError(
            try runtime.run(.init(
                command: ["/usr/bin/true"],
                credentialNames: ["First Credential", "Missing Credential"]
            ))
        ) { error in
            XCTAssertEqual(error as? BrokerTextRuntimeError, .invalidCredentialMapping)
        }
    }

    func testDisconnectTerminatesTheChildAndSpawnBoundaryFailureIsNotRetried() throws {
        let control = Pipe()
        let cancellation = BrokerCancellation()
        let runtime = BrokerTextRuntime(resolveCredentials: { _, _ in
            .resolved([.init(environmentVariable: "TOKEN", value: "secret")])
        })
        let finished = expectation(description: "child terminated")
        let result = LockedResult()
        DispatchQueue.global().async {
            result.value = try? runtime.run(
                .init(command: ["/bin/sleep", "30"], credentialNames: ["TOKEN"]),
                controlFD: control.fileHandleForReading.fileDescriptor,
                cancellation: cancellation
            )
            finished.fulfill()
        }
        usleep(100_000)
        try control.fileHandleForWriting.close()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(result.value, .exited(143))

        let hookCalls = LockedCounter()
        let crashing = BrokerTextRuntime(
            resolveCredentials: { _, _ in .resolved([.init(environmentVariable: "TOKEN", value: "secret")]) },
            afterSpawn: {
                hookCalls.increment()
                throw BrokerTextRuntimeError.spawnFailed
            }
        )
        XCTAssertEqual(
            try crashing.run(.init(command: ["/bin/sleep", "30"], credentialNames: ["TOKEN"])),
            .outcomeUnknown
        )
        XCTAssertEqual(hookCalls.value, 1)
    }

    func testInterruptIsForwardedToTheTargetProcess() throws {
        let control = Pipe()
        let runtime = BrokerTextRuntime(resolveCredentials: { _, _ in
            .resolved([.init(environmentVariable: "TOKEN", value: "secret")])
        })
        let finished = expectation(description: "interrupted")
        let result = LockedResult()
        DispatchQueue.global().async {
            result.value = try? runtime.run(
                .init(command: ["/bin/sleep", "30"], credentialNames: ["TOKEN"]),
                controlFD: control.fileHandleForReading.fileDescriptor
            )
            finished.fulfill()
        }
        usleep(100_000)
        var interrupt = BrokerRuntimeSignal.interrupt.rawValue
        XCTAssertEqual(write(control.fileHandleForWriting.fileDescriptor, &interrupt, 1), 1)
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(result.value, .exited(130))
    }

    func testCancellationForceKillsATargetThatIgnoresTermination() throws {
        let cancellation = BrokerCancellation()
        let ready = Pipe()
        let runtime = BrokerTextRuntime(
            resolveCredentials: { _, _ in
                .resolved([.init(environmentVariable: "TOKEN", value: "secret")])
            },
            terminationGrace: 0.05,
            forceKillGrace: 0.5
        )
        let finished = expectation(description: "force killed")
        let result = LockedResult()
        DispatchQueue.global().async {
            result.value = try? runtime.run(
                .init(
                    command: [
                        "/bin/sh", "-c",
                        "trap '' TERM; /bin/sh -c 'trap \"\" TERM; while :; do sleep 1; done' & child=$!; printf '%010d\\n' \"$child\"; wait",
                    ],
                    credentialNames: ["TOKEN"]
                ),
                standardOutputFD: ready.fileHandleForWriting.fileDescriptor,
                cancellation: cancellation
            )
            finished.fulfill()
        }
        let childPIDText = String(
            decoding: try ready.fileHandleForReading.read(upToCount: 11) ?? Data(), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let childPID = Int32(childPIDText) else { return XCTFail("missing child pid") }
        defer { if kill(childPID, 0) == 0 { _ = kill(childPID, SIGKILL) } }
        cancellation.cancel()

        wait(for: [finished], timeout: 2)
        XCTAssertEqual(result.value, .exited(137))
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testSpawnBoundaryFailureForceKillsATargetThatIgnoresTermination() throws {
        let ready = Pipe()
        let runtime = BrokerTextRuntime(
            resolveCredentials: { _, _ in
                .resolved([.init(environmentVariable: "TOKEN", value: "secret")])
            },
            afterSpawn: {
                _ = try ready.fileHandleForReading.read(upToCount: 5)
                throw BrokerTextRuntimeError.spawnFailed
            },
            terminationGrace: 0.05,
            forceKillGrace: 0.5
        )

        XCTAssertEqual(
            try runtime.run(
                .init(
                    command: ["/bin/sh", "-c", "trap '' TERM; printf ready; while :; do sleep 1; done"],
                    credentialNames: ["TOKEN"]
                ),
                standardOutputFD: ready.fileHandleForWriting.fileDescriptor
            ),
            .outcomeUnknown
        )
    }

    func testCancellationKillsTheRemainingGroupAfterLeaderExit() throws {
        let cancellation = BrokerCancellation()
        let ready = Pipe()
        let childPID = LockedPID()
        let runtime = BrokerTextRuntime(
            resolveCredentials: { _, _ in
                .resolved([.init(environmentVariable: "TOKEN", value: "secret")])
            },
            afterSpawn: {
                let text = String(
                    decoding: try ready.fileHandleForReading.read(upToCount: 11) ?? Data(),
                    as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                childPID.value = Int32(text)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    cancellation.cancel()
                }
            },
            terminationGrace: 0.05,
            forceKillGrace: 0.5
        )

        XCTAssertEqual(
            try runtime.run(
                .init(
                    command: [
                        "/bin/sh", "-c",
                        "/bin/sh -c 'trap \"\" TERM; while :; do sleep 1; done' & child=$!; printf '%010d\\n' \"$child\"; exit 0",
                    ],
                    credentialNames: ["TOKEN"]
                ),
                standardOutputFD: ready.fileHandleForWriting.fileDescriptor,
                cancellation: cancellation
            ),
            .exited(0)
        )
        guard let pid = childPID.value else { return XCTFail("missing child pid") }
        defer { if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) } }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class LockedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BrokerTextRunResult?
    var value: BrokerTextRunResult? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class LockedPID: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32?
    var value: Int32? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
