import Foundation

public enum BrokerProtocolVersion {
    public static let current = 1
}

public enum BrokerConfiguration {
    /// Compatibility projection for read-only path display. Explicit invalid
    /// debug isolation is never allowed to fall back to a real vault namespace.
    public static var socketURL: URL {
        (try? resolvedSocketURL()) ?? URL(fileURLWithPath: "/dev/null/askkey-invalid-debug-directory.sock")
    }

    public static func resolvedSocketURL() throws -> URL {
        if let root = try DebugRunDirectory.resolve() {
            return root.appendingPathComponent("daemon.sock")
        }
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["ASKKEY_BROKER_SOCKET"],
           override.hasPrefix("/") {
            return URL(fileURLWithPath: override)
        }
        let subdirectory = "AskKey/dev"
        #else
        let subdirectory = "AskKey"
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(subdirectory)
            .appendingPathComponent("daemon.sock")
    }
}

public enum BrokerLimits {
    public static let maximumFrameBytes = 64 * 1024
    public static let maximumResponseBytes = 64 * 1024
    public static let maximumFieldBytes = 4 * 1024
    public static let maximumConnections = 16
    public static let maximumRequestsPerConnection = 32
    public static let maximumConcurrentRequests = 8
    public static let maximumRuntimeReceiptCount = 65_536
    public static let maximumQueuedRequests = 32
    public static let maximumPendingApprovalRequests = 64
    public static let maximumRetainedRequestStates = 256
    public static let readDeadline: TimeInterval = 2
    public static let requestDeadline: TimeInterval = 1
    public static let writeDeadline: TimeInterval = 2
}

public struct BrokerRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let method: String
    public let requestID: String?
    public let capability: String?
    public let textRun: BrokerTextRunRequest?
    public let fileWrite: BrokerFileWriteRequest?
    public let operationID: String?
    public let textWrite: AgentTextWriteRequest?

    public init(
        version: Int,
        method: String,
        requestID: String? = nil,
        capability: String? = nil,
        textRun: BrokerTextRunRequest? = nil,
        fileWrite: BrokerFileWriteRequest? = nil,
        operationID: String? = nil,
        textWrite: AgentTextWriteRequest? = nil
    ) {
        self.version = version
        self.method = method
        self.requestID = requestID
        self.capability = capability
        self.textRun = textRun
        self.fileWrite = fileWrite
        self.operationID = operationID
        self.textWrite = textWrite
    }
}

public struct BrokerFileWriteBeginRequest: Codable, Equatable, Sendable {
    public let operationID: String
    public let credentialID: String
    public let targetID: String
    public let operation: BrokerApprovalOperation
    public let originalFilename: String
    public let expectedByteCount: Int

    public init(
        operationID: String,
        credentialID: String,
        targetID: String,
        operation: BrokerApprovalOperation,
        originalFilename: String,
        expectedByteCount: Int
    ) {
        self.operationID = operationID
        self.credentialID = credentialID
        self.targetID = targetID
        self.operation = operation
        self.originalFilename = originalFilename
        self.expectedByteCount = expectedByteCount
    }
}

public struct BrokerFileWriteChunkRequest: Codable, Equatable, Sendable {
    public let uploadID: String
    public let capability: String
    public let offset: Int
    public let bytes: Data

    public init(uploadID: String, capability: String, offset: Int, bytes: Data) {
        self.uploadID = uploadID
        self.capability = capability
        self.offset = offset
        self.bytes = bytes
    }
}

public struct BrokerFileWriteFreezeRequest: Codable, Equatable, Sendable {
    public let uploadID: String
    public let capability: String

    public init(uploadID: String, capability: String) {
        self.uploadID = uploadID
        self.capability = capability
    }
}

public enum BrokerFileWriteRequest: Codable, Equatable, Sendable {
    case beginComponent(BrokerComponentUploadBeginRequest)
    case freezeComponent(BrokerFileWriteFreezeRequest)
    case cancelUpload(BrokerFileWriteFreezeRequest)
    case begin(BrokerFileWriteBeginRequest)
    case append(BrokerFileWriteChunkRequest)
    case freeze(BrokerFileWriteFreezeRequest)
}

public enum BrokerFileWritePayload: Codable, Equatable, Sendable {
    case componentFrozen(BrokerComponentFileReference)
    case uploadCancelled
    case upload(BrokerFileUploadTicket)
    case chunkAccepted(nextOffset: Int)
    case approval(BrokerApprovalTicket)
}

public enum AgentTextWriteAction: Codable, Equatable, Sendable {
    case createBundle(name: String, components: [BrokerCredentialComponentInput])
    case modifyBundle(name: String, changes: [BrokerCredentialComponentChange])
    case create(name: String, value: String)
    case modify(name: String, value: String)
    case delete(name: String)
}

public struct AgentTextWriteRequest: Codable, Equatable, Sendable {
    public let operationID: String
    public let action: AgentTextWriteAction
    public let callerName: String?
    public let callerPurpose: String?

    public init(
        operationID: String,
        action: AgentTextWriteAction,
        callerName: String? = nil,
        callerPurpose: String? = nil
    ) {
        self.operationID = operationID
        self.action = action
        self.callerName = callerName
        self.callerPurpose = callerPurpose
    }
}

public struct AgentTextWriteSubmission: Codable, Equatable, Sendable {
    public let operationID: String
    public let requestID: String
    public let capability: String
    public let state: BrokerRequestState
    public let retryCount: Int

    public init(operationID: String, requestID: String, capability: String, state: BrokerRequestState, retryCount: Int) {
        self.operationID = operationID
        self.requestID = requestID
        self.capability = capability
        self.state = state
        self.retryCount = retryCount
    }
}

public struct AgentTextWriteResult: Codable, Equatable, Sendable {
    public let operationID: String
    public let credentialID: String
    public let state: BrokerRequestState

    public init(operationID: String, credentialID: String, state: BrokerRequestState = .completed) {
        self.operationID = operationID
        self.credentialID = credentialID
        self.state = state
    }
}

public enum AgentTextWriteRequestOutcome: Codable, Equatable, Sendable {
    case submitted(AgentTextWriteSubmission)
    case completed(AgentTextWriteResult)
}

public struct BrokerHealth: Codable, Equatable, Sendable {
    public let version: Int
    public let status: String

    public init(version: Int, status: String) {
        self.version = version
        self.status = status
    }
}

public struct BrokerVersion: Codable, Equatable, Sendable {
    public let protocolVersion: Int

    public init(protocolVersion: Int) {
        self.protocolVersion = protocolVersion
    }
}

public enum BrokerCatalogPayloadKind: String, Codable, Equatable, Sendable {
    case text
    case file
}

public struct BrokerCatalogItem: Codable, Equatable, Sendable {
    public let credentialID: String?
    public let components: [BrokerCatalogComponent]?
    public let name: String
    public let payloadKind: BrokerCatalogPayloadKind
    public let usageInstructions: String
    public let environmentVariable: String?
    public let expired: Bool

    public init(credentialID: String? = nil, name: String, payloadKind: BrokerCatalogPayloadKind, usageInstructions: String, environmentVariable: String?, expired: Bool, components: [BrokerCatalogComponent]? = nil) {
        self.credentialID = credentialID
        self.components = components
        self.name = name
        self.payloadKind = payloadKind
        self.usageInstructions = usageInstructions
        self.environmentVariable = environmentVariable
        self.expired = expired
    }
}

public enum BrokerRequestState: String, Codable, Equatable, Sendable {
    case pending
    case approved
    case denied
    case cancelled
    case expired
    case completed
    case consumed
    case outcomeUnknown = "outcome_unknown"
}

public enum BrokerPayload: Codable, Equatable, Sendable {
    case health(BrokerHealth)
    case version(BrokerVersion)
    case catalog([BrokerCatalogItem])
    case requestStatus(BrokerRequestState)
    case textRun(BrokerTextRunResult)
    case fileWrite(BrokerFileWritePayload)
    case textWriteRequest(AgentTextWriteRequestOutcome)
    case textWriteResult(AgentTextWriteResult)
}

public enum BrokerErrorCode: String, Codable, Equatable, Sendable {
    case unsupportedVersion = "unsupported_version"
    case methodNotAllowed = "method_not_allowed"
    case invalidRequest = "invalid_request"
    case requestNotFound = "request_not_found"
    case resourceExhausted = "resource_exhausted"
    case deadlineExceeded = "deadline_exceeded"
    case responseTooLarge = "response_too_large"
    case internalError = "internal_error"
    case agentAccessPaused = "agent_access_paused"
    case requestRejected = "request_rejected"
}

public enum BrokerProviderError: Error, Equatable {
    case agentAccessPaused
    case requestRejected
    case invalidRequest
    case requestNotFound
    case resourceExhausted
}

public enum BrokerResponse: Codable, Equatable, Sendable {
    case success(BrokerPayload)
    case failure(BrokerErrorCode)
}

public enum BrokerRequestRegistryError: Error, Equatable {
    case capacityReached
    case duplicateRequest
    case agentAccessPaused
}

public enum BrokerCancellationError: Error {
    case cancelled
}

// Safe: cancellation state and callbacks are protected by the condition lock.
public final class BrokerCancellation: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false
    private var callbacks: [@Sendable () -> Void] = []

    public init() {}

    public func cancel() {
        condition.lock()
        guard !cancelled else { condition.unlock(); return }
        cancelled = true
        let pendingCallbacks = callbacks
        callbacks.removeAll()
        condition.broadcast()
        condition.unlock()
        pendingCallbacks.forEach { $0() }
    }

    public func onCancel(_ callback: @escaping @Sendable () -> Void) {
        condition.lock()
        if cancelled {
            condition.unlock()
            callback()
        } else {
            callbacks.append(callback)
            condition.unlock()
        }
    }

    public func check() throws {
        condition.lock(); defer { condition.unlock() }
        if cancelled { throw BrokerCancellationError.cancelled }
    }

    public var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled
    }

    public func waitUntilCancelled() {
        condition.lock(); defer { condition.unlock() }
        while !cancelled { condition.wait() }
    }
}

/// Capability-bound request state owned by the App. Later request-producing
/// stages register operations here; public callers can only query or cancel an
/// entry when both its id and unguessable capability match.
// Safe: every access to mutable state is lock-guarded.
public final class BrokerRequestRegistry: @unchecked Sendable {
    private struct PendingState {
        let capability: String
        let credentialID: String?
    }

    private struct RetainedState {
        let capability: String
        var state: BrokerRequestState
    }

    private let lock = NSLock()
    private var pendingStates: [String: PendingState] = [:]
    private var retainedStates: [String: RetainedState] = [:]
    private var retainedOrder: [String] = []
    private var paused = false

    public init() {}

    public func register(requestID: String, capability: String, credentialID: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard !paused else { throw BrokerRequestRegistryError.agentAccessPaused }
        guard pendingStates[requestID] == nil, retainedStates[requestID] == nil else {
            throw BrokerRequestRegistryError.duplicateRequest
        }
        guard pendingStates.count < BrokerLimits.maximumPendingApprovalRequests else {
            throw BrokerRequestRegistryError.capacityReached
        }
        pendingStates[requestID] = PendingState(capability: capability, credentialID: credentialID)
    }

    public func status(requestID: String, capability: String) -> BrokerRequestState? {
        lock.lock(); defer { lock.unlock() }
        if pendingStates[requestID]?.capability == capability { return .pending }
        guard let retained = retainedStates[requestID], retained.capability == capability else { return nil }
        return retained.state
    }

    public func cancel(requestID: String, capability: String) -> BrokerRequestState? {
        lock.lock(); defer { lock.unlock() }
        if pendingStates[requestID]?.capability == capability {
            pendingStates.removeValue(forKey: requestID)
            retain(requestID: requestID, capability: capability, state: .cancelled)
            return .cancelled
        }
        guard let retained = retainedStates[requestID], retained.capability == capability else { return nil }
        return retained.state
    }

    @discardableResult
    public func cancelAllPending() -> Int {
        lock.lock(); defer { lock.unlock() }
        return cancelAllPendingLocked()
    }

    @discardableResult
    public func cancelPending(credentialID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let matching = pendingStates.filter { $0.value.credentialID == credentialID }
        for (requestID, pending) in matching {
            pendingStates.removeValue(forKey: requestID)
            retain(requestID: requestID, capability: pending.capability, state: .cancelled)
        }
        return matching.count
    }

    public func pauseAndCancelAll() {
        lock.lock(); defer { lock.unlock() }
        paused = true
        _ = cancelAllPendingLocked()
    }

    public func resume() {
        lock.lock(); defer { lock.unlock() }
        paused = false
    }

    private func cancelAllPendingLocked() -> Int {
        let pending = pendingStates
        pendingStates.removeAll()
        for (requestID, state) in pending {
            retain(requestID: requestID, capability: state.capability, state: .cancelled)
        }
        return pending.count
    }

    @discardableResult
    public func setState(requestID: String, capability: String, state: BrokerRequestState) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if state == .pending { return pendingStates[requestID]?.capability == capability }
        if pendingStates[requestID]?.capability == capability {
            pendingStates.removeValue(forKey: requestID)
            retain(requestID: requestID, capability: capability, state: state)
            return true
        }
        guard let retained = retainedStates[requestID], retained.capability == capability else { return false }
        return retained.state == state
    }

    private func retain(requestID: String, capability: String, state: BrokerRequestState) {
        retainedStates[requestID] = RetainedState(capability: capability, state: state)
        retainedOrder.append(requestID)
        if retainedOrder.count > BrokerLimits.maximumRetainedRequestStates {
            retainedStates.removeValue(forKey: retainedOrder.removeFirst())
        }
    }
}

public struct BrokerRequestHandler: Sendable {
    public typealias CatalogProvider = @Sendable (BrokerCancellation) throws -> [BrokerCatalogItem]
    public typealias RequestStatusProvider = @Sendable (String, String) throws -> BrokerRequestState?
    public typealias RequestCancellationProvider = @Sendable (String, String) throws -> BrokerRequestState?
    public typealias TextRunProvider = @Sendable (
        BrokerTextRunRequest, BrokerPassedFileDescriptors, BrokerCancellation
    ) throws -> BrokerTextRunResult
    public typealias FileWriteProvider = @Sendable (
        BrokerFileWriteRequest
    ) throws -> BrokerFileWritePayload
    public typealias TextWriteSubmissionProvider = @Sendable (AgentTextWriteRequest, BrokerCancellation) throws -> AgentTextWriteRequestOutcome
    public typealias TextWriteCommitProvider = @Sendable (AgentTextWriteRequest, String, String) throws -> AgentTextWriteResult
    public typealias TextWriteCancellationProvider = @Sendable (String, String, String) throws -> BrokerRequestState

    private let catalog: CatalogProvider
    private let requestStatus: RequestStatusProvider
    private let cancelRequest: RequestCancellationProvider
    private let textRun: TextRunProvider?
    private let fileWrite: FileWriteProvider?
    private let submitTextWrite: TextWriteSubmissionProvider?
    private let commitTextWrite: TextWriteCommitProvider?
    private let cancelTextWrite: TextWriteCancellationProvider?

    public init(
        catalog: @escaping CatalogProvider,
        requestStatus: @escaping RequestStatusProvider,
        cancelRequest: @escaping RequestCancellationProvider = { _, _ in nil },
        textRun: TextRunProvider? = nil,
        fileWrite: FileWriteProvider? = nil,
        submitTextWrite: TextWriteSubmissionProvider? = nil,
        commitTextWrite: TextWriteCommitProvider? = nil,
        cancelTextWrite: TextWriteCancellationProvider? = nil
    ) {
        self.catalog = catalog
        self.requestStatus = requestStatus
        self.cancelRequest = cancelRequest
        self.textRun = textRun
        self.fileWrite = fileWrite
        self.submitTextWrite = submitTextWrite
        self.commitTextWrite = commitTextWrite
        self.cancelTextWrite = cancelTextWrite
    }

    public func handle(
        _ request: BrokerRequest,
        descriptors: BrokerPassedFileDescriptors? = nil,
        cancellation: BrokerCancellation = BrokerCancellation()
    ) -> BrokerResponse {
        guard request.version == BrokerProtocolVersion.current else {
            return .failure(.unsupportedVersion)
        }
        guard Self.fieldsFit(request) else { return .failure(.invalidRequest) }
        guard request.method == "runtime.run" || request.textRun == nil,
              request.method == "credential.file.write" || request.fileWrite == nil,
              request.method.hasPrefix("credential.write.") || request.textWrite == nil,
              request.method == "credential.write.cancel" || request.operationID == nil else {
            return .failure(.invalidRequest)
        }

        do {
            switch request.method {
            case "health":
                return .success(.health(.init(version: BrokerProtocolVersion.current, status: "ok")))
            case "version":
                return .success(.version(.init(protocolVersion: BrokerProtocolVersion.current)))
            case "catalog":
                try cancellation.check()
                let items = try catalog(cancellation)
                try cancellation.check()
                guard items.allSatisfy(Self.catalogFieldsFit) else {
                    return .failure(.internalError)
                }
                return .success(.catalog(items))
            case "request.status":
                guard let requestID = request.requestID, let capability = request.capability else {
                    return .failure(.invalidRequest)
                }
                guard let status = try requestStatus(requestID, capability) else {
                    return .failure(.requestNotFound)
                }
                return .success(.requestStatus(status))
            case "request.cancel":
                guard let requestID = request.requestID, let capability = request.capability else {
                    return .failure(.invalidRequest)
                }
                guard let status = try cancelRequest(requestID, capability) else {
                    return .failure(.requestNotFound)
                }
                return .success(.requestStatus(status))
            case "runtime.run":
                guard let textRun, let runRequest = request.textRun, let descriptors else {
                    return .failure(.invalidRequest)
                }
                return .success(.textRun(try textRun(runRequest, descriptors, cancellation)))
            case "credential.file.write":
                guard let fileWrite, let fileRequest = request.fileWrite,
                      request.requestID == nil, request.capability == nil,
                      request.textRun == nil else {
                    return .failure(.invalidRequest)
                }
                return .success(.fileWrite(try fileWrite(fileRequest)))
            case "credential.write.request":
                guard let write = request.textWrite, let submitTextWrite else {
                    return .failure(.invalidRequest)
                }
                try cancellation.check()
                let outcome = try submitTextWrite(write, cancellation)
                do {
                    try cancellation.check()
                } catch {
                    if case let .submitted(submission) = outcome {
                        cancelSubmittedTextWrite(
                            write.operationID,
                            submission.requestID,
                            submission.capability
                        )
                    }
                    throw error
                }
                return .success(.textWriteRequest(outcome))
            case "credential.write.commit":
                guard let write = request.textWrite,
                      let requestID = request.requestID,
                      let capability = request.capability,
                      let commitTextWrite else {
                    return .failure(.invalidRequest)
                }
                return .success(.textWriteResult(try commitTextWrite(write, requestID, capability)))
            case "credential.write.cancel":
                guard let operationID = request.operationID,
                      let requestID = request.requestID,
                      let capability = request.capability,
                      let cancelTextWrite else {
                    return .failure(.invalidRequest)
                }
                return .success(.requestStatus(try cancelTextWrite(operationID, requestID, capability)))
            default:
                return .failure(.methodNotAllowed)
            }
        } catch BrokerProviderError.agentAccessPaused {
            return .failure(.agentAccessPaused)
        } catch BrokerProviderError.requestRejected {
            return .failure(.requestRejected)
        } catch let error as BrokerTextRuntimeError {
            switch error {
            case .missingCommand, .missingCredentials, .invalidRequest,
                 .invalidWorkingDirectory, .invalidCredentialMapping:
                return .failure(.invalidRequest)
            case .spawnFailed:
                return .failure(.internalError)
            }
        } catch let error as BrokerFileWriteError {
            switch error {
            case .invalidRequest, .outOfOrderChunk, .truncatedUpload, .alreadyFrozen:
                return .failure(.invalidRequest)
            case .invalidCapability, .requestNotFound:
                return .failure(.requestNotFound)
            case .tooLarge, .capacityReached:
                return .failure(.resourceExhausted)
            case .digestMismatch, .targetChanged, .authenticationFailed:
                return .failure(.requestRejected)
            case .outcomeUnknown:
                return .failure(.internalError)
            case .stagingFailed, .stagingNotADirectory, .stagingPermissionDenied:
                return .failure(.internalError)
            }
        } catch BrokerApprovalError.requestNotFound {
            // Capability mismatches, including durable file receipts, have the
            // same external result as an unknown request. Provider closures need
            // not translate this domain error before crossing the wire boundary.
            return .failure(.requestNotFound)
        } catch BrokerApprovalError.payloadMismatch {
            return .failure(.requestRejected)
        } catch BrokerApprovalError.agentAccessPaused {
            return .failure(.agentAccessPaused)
        } catch BrokerApprovalError.capacityReached {
            return .failure(.resourceExhausted)
        } catch BrokerProviderError.invalidRequest {
            return .failure(.invalidRequest)
        } catch BrokerProviderError.requestNotFound {
            return .failure(.requestNotFound)
        } catch BrokerProviderError.resourceExhausted {
            return .failure(.resourceExhausted)
        } catch BrokerCancellationError.cancelled {
            return .failure(.deadlineExceeded)
        } catch {
            return .failure(.internalError)
        }
    }

    private static func fieldsFit(_ request: BrokerRequest) -> Bool {
        let envelopeFits = [request.method, request.requestID, request.capability, request.operationID]
            .compactMap { $0 }
            .allSatisfy { $0.utf8.count <= BrokerLimits.maximumFieldBytes }
        guard envelopeFits, let write = request.textWrite else { return envelopeFits }
        return write.isBounded
    }

    func cancelUndelivered(_ request: BrokerRequest, response: BrokerResponse) {
        guard request.method == "credential.write.request",
              let operationID = request.textWrite?.operationID,
              case let .success(.textWriteRequest(.submitted(submission))) = response else { return }
        cancelSubmittedTextWrite(operationID, submission.requestID, submission.capability)
    }

    private func cancelSubmittedTextWrite(
        _ operationID: String,
        _ requestID: String,
        _ capability: String
    ) {
        guard let cancelTextWrite else { return }
        do {
            _ = try cancelTextWrite(operationID, requestID, capability)
        } catch {
            NSLog("Ask Key Broker could not cancel an undelivered write submission.")
        }
    }

    private static func catalogFieldsFit(_ item: BrokerCatalogItem) -> Bool {
        let fields: [String?] = [item.credentialID, item.name, item.usageInstructions, item.environmentVariable]
            + (item.components ?? []).flatMap { component -> [String?] in [component.name, component.delivery.environmentVariable] }
        return (item.components?.count ?? 0) <= 64 && fields.compactMap { $0 }
            .allSatisfy { $0.utf8.count <= BrokerLimits.maximumFieldBytes }
    }
}
