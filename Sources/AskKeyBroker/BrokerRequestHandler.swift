import Foundation

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
