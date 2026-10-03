import CryptoKit
import Darwin
import Foundation
import AskKeyBroker

/// A process-scoped Broker fixture for the natural credential-discovery flow.
///
/// The fixture deliberately has no vault, no network client, and no shell
/// entrypoint.  The caller supplies the one read-only inspection executable;
/// the Broker accepts exactly that executable with exactly one synthetic
/// credential.  The debug `askkey` helper is run by the surrounding E2E
/// orchestrator, so this process remains alive until it receives SIGTERM.
@main
struct CredentialDiscoveryBroker {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("Credential discovery fixture failed.\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else { throw FixtureError.usage }

        let inputRoot = try validatedRoot(arguments[0])
        let inspectionExecutable = try validatedInspectionExecutable(arguments[1])
        try prepareRoot(inputRoot)
        let root = try canonicalRoot(inputRoot)

        let events = try FixtureEventLog(url: root.appendingPathComponent("events.jsonl"))
        let approvals = BrokerApprovalStateMachine(authenticate: { _ in true })
        let state = FixtureState(
            root: root,
            inspectionExecutable: inspectionExecutable,
            approvals: approvals,
            events: events
        )
        let runtime = BrokerTextRuntime(
            resolveCredentials: { request, cancellation in
                try state.resolveCredentials(for: request, cancellation: cancellation)
            },
            beforeSystemSpawn: {
                try state.recordAuthorizedSpawn()
            }
        )
        let server = BrokerSocketServer(
            socketPath: root.appendingPathComponent("broker.sock").path,
            handler: .init(
                catalog: { cancellation in
                    try cancellation.check()
                    return state.catalog()
                },
                requestStatus: { requestID, capability in
                    state.recordStatus()
                    return try? approvals.status(requestID: requestID, capability: capability)
                },
                cancelRequest: { requestID, capability in
                    state.recordCancellation()
                    return try? approvals.cancel(requestID: requestID, capability: capability)
                },
                textRun: { request, descriptors, cancellation in
                    try state.validateTextRun(request)
                    let result = try runtime.run(
                        request,
                        standardInputFD: descriptors.standardInput,
                        standardOutputFD: descriptors.standardOutput,
                        standardErrorFD: descriptors.standardError,
                        controlFD: descriptors.control,
                        cancellation: cancellation
                    )
                    if case .exited = result {
                        events.record("completed", operationID: request.operationID)
                    }
                    return result
                }
            )
        )

        try server.start()
        events.record("started")
        let lifecycle = FixtureLifecycle(server: server, events: events)
        lifecycle.installSignalHandlers()
        dispatchMain()
    }

    private static func validatedRoot(_ raw: String) throws -> URL {
        guard isSafeAbsolutePath(raw), raw != "/tmp", raw.hasPrefix("/tmp/") else {
            throw FixtureError.invalidRoot
        }
        let root = URL(fileURLWithPath: raw, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard root.path.utf8.count <= 72 else { throw FixtureError.invalidRoot }
        return root
    }

    private static func validatedInspectionExecutable(_ raw: String) throws -> URL {
        guard isSafeAbsolutePath(raw) else { throw FixtureError.invalidExecutable }
        let executable = URL(fileURLWithPath: raw).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw FixtureError.invalidExecutable
        }
        return executable
    }

    private static func canonicalRoot(_ root: URL) throws -> URL {
        guard let pointer = realpath(root.path, nil) else { throw FixtureError.invalidRoot }
        let resolvedPath = String(cString: pointer)
        free(pointer)
        guard resolvedPath.hasPrefix("/private/tmp/") else { throw FixtureError.invalidRoot }
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }

    private static func prepareRoot(_ root: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw FixtureError.invalidRoot }
        } else {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let eventsPath = root.appendingPathComponent("events.jsonl").path
        guard !FileManager.default.fileExists(atPath: eventsPath) else {
            throw FixtureError.rootAlreadyUsed
        }
    }

    private static func isSafeAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}

private enum FixtureError: Error {
    case usage
    case invalidRoot
    case invalidExecutable
    case rootAlreadyUsed
}

private enum FixtureConstants {
    static let credentialName = "家庭 NAS" // i18n-literal: Preserve the synthetic Unicode credential name used by the discovery fixture.
    static let credentialID = "fixture-family-nas"
    static let environmentVariable = "NAS_TEST_TOKEN"
    static let syntheticToken = "fixture-only-synthetic-nas-token"
}

private final class FixtureEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var counts: [String: Int] = [:]

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw FixtureError.rootAlreadyUsed
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func record(_ event: String, operationID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        counts[event, default: 0] += 1
        var payload: [String: Any] = [
            "event": event,
            "count": counts[event] ?? 0,
        ]
        if let operationID { payload["operation_id"] = operationID }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        var line = data
        line.append(0x0A)
        try? handle.write(contentsOf: line)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.close()
    }
}

private final class FixtureState: @unchecked Sendable {
    private let root: URL
    private let inspectionExecutable: URL
    private let approvals: BrokerApprovalStateMachine
    private let events: FixtureEventLog
    private let lock = NSLock()

    private var firstRequest: BrokerTextRunRequest?
    private var operationRequest: BrokerApprovalOperationRequest?
    private var approvalTicket: BrokerApprovalTicket?
    private var resolverCalls = 0
    private var approvalScheduled = false
    private var approvalConsumed = false
    private var spawnCount = 0

    init(
        root: URL,
        inspectionExecutable: URL,
        approvals: BrokerApprovalStateMachine,
        events: FixtureEventLog
    ) {
        self.root = root
        self.inspectionExecutable = inspectionExecutable
        self.approvals = approvals
        self.events = events
    }

    func catalog() -> [BrokerCatalogItem] {
        events.record("catalog")
        return [
            BrokerCatalogItem(
                credentialID: FixtureConstants.credentialID,
                name: FixtureConstants.credentialName,
                payloadKind: .text,
                usageInstructions: "To check the SSH key status of this family NAS, run "
                    + inspectionExecutable.path
                    + " directly without arguments. Ask Key supplies the credential through the NAS_TEST_TOKEN environment variable; the program output is the inspection result.",
                environmentVariable: FixtureConstants.environmentVariable,
                expired: false
            )
        ]
    }

    func validateTextRun(_ request: BrokerTextRunRequest) throws {
        guard request.command == [inspectionExecutable.path],
              request.credentialNames == [FixtureConstants.credentialName],
              request.workingDirectory == root.path else {
            events.record("rejected")
            throw BrokerTextRuntimeError.invalidRequest
        }
        events.record("text_run", operationID: request.operationID)
    }

    func resolveCredentials(
        for request: BrokerTextRunRequest,
        cancellation: BrokerCancellation
    ) throws -> BrokerTextCredentialResolution {
        try cancellation.check()
        let firstCall: Bool
        lock.lock()
        resolverCalls += 1
        firstCall = firstRequest == nil
        if let firstRequest {
            guard firstRequest == request else {
                lock.unlock()
                events.record("rejected")
                throw BrokerTextRuntimeError.invalidRequest
            }
        } else {
            firstRequest = request
        }
        lock.unlock()

        guard request.command == [inspectionExecutable.path],
              request.credentialNames == [FixtureConstants.credentialName],
              request.workingDirectory == root.path else {
            events.record("rejected")
            throw BrokerTextRuntimeError.invalidRequest
        }

        let operation = try makeOperationRequest(for: request)
        let ticket = try approvals.submit(
            operation,
            trustedCredentialDeadline: .none,
            trustedCredentialName: FixtureConstants.credentialName
        )
        lock.lock()
        operationRequest = operation
        approvalTicket = ticket
        lock.unlock()

        switch ticket.state {
        case .pending:
            if firstCall {
                events.record("pending", operationID: request.operationID)
                scheduleApproval(for: ticket, operationID: request.operationID)
            } else {
                events.record("pending_retry", operationID: request.operationID)
            }
            return .approvalRequired([ticket])
        case .approved:
            guard !firstCall else {
                events.record("rejected", operationID: request.operationID)
                throw BrokerTextRuntimeError.invalidRequest
            }
            _ = try approvals.consume(
                requestID: ticket.requestID,
                capability: ticket.capability,
                operationRequest: operation
            )
            lock.lock()
            approvalConsumed = true
            lock.unlock()
            events.record("consumed", operationID: request.operationID)
            return .resolved(
                [BrokerTextCredential(environmentVariable: FixtureConstants.environmentVariable, value: FixtureConstants.syntheticToken)],
                resolvedRequestCount: 1
            )
        default:
            events.record("rejected", operationID: request.operationID)
            throw BrokerTextRuntimeError.invalidRequest
        }
    }

    func recordStatus() {
        events.record("status")
    }

    func recordCancellation() {
        events.record("cancel")
    }

    func recordAuthorizedSpawn() throws {
        lock.lock()
        let authorized = approvalConsumed
        if authorized { spawnCount += 1 }
        lock.unlock()
        guard authorized else {
            events.record("rejected")
            throw BrokerTextRuntimeError.invalidRequest
        }
        events.record("spawn")
    }

    private func makeOperationRequest(for request: BrokerTextRunRequest) throws -> BrokerApprovalOperationRequest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(request)
        let digest = SHA256.hash(data: encoded)
            .map { String(format: "%02x", $0) }
            .joined()
        return BrokerApprovalOperationRequest(
            operationID: request.operationID,
            credentialID: FixtureConstants.credentialID,
            targetID: FixtureConstants.credentialID,
            operation: .read,
            payloadDigest: digest,
            credentialName: FixtureConstants.credentialName,
            callerName: request.sanitizedCallerName,
            callerPurpose: request.sanitizedCallerPurpose
        )
    }

    private func scheduleApproval(for ticket: BrokerApprovalTicket, operationID: String) {
        lock.lock()
        guard !approvalScheduled else {
            lock.unlock()
            return
        }
        approvalScheduled = true
        lock.unlock()
        events.record("approval_scheduled", operationID: operationID)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [approvals, events] in
            do {
                _ = try approvals.decide(
                    requestID: ticket.requestID,
                    capability: ticket.capability,
                    decision: .once
                )
                events.record("approved", operationID: operationID)
            } catch {
                events.record("approval_failed", operationID: operationID)
            }
        }
    }
}

private final class FixtureLifecycle: @unchecked Sendable {
    private let server: BrokerSocketServer
    private let events: FixtureEventLog
    private let lock = NSLock()
    private var signalSources: [DispatchSourceSignal] = []
    private var stopped = false

    init(server: BrokerSocketServer, events: FixtureEventLog) {
        self.server = server
        self.events = events
    }

    func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in self?.stopAndExit() }
        source.resume()
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { [weak self] in self?.stopAndExit() }
        interrupt.resume()
        lock.lock()
        signalSources = [source, interrupt]
        lock.unlock()
    }

    private func stopAndExit() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        server.stop()
        events.record("stopped")
        events.close()
        exit(EXIT_SUCCESS)
    }
}
