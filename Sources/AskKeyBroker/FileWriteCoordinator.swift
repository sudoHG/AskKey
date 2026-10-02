import CryptoKit
import Darwin
import Foundation

public enum BrokerFileWriteError: Error, Equatable {
    case invalidRequest
    case invalidCapability
    case outOfOrderChunk
    case tooLarge
    case capacityReached
    case truncatedUpload
    case alreadyFrozen
    case requestNotFound
    case digestMismatch
    case targetChanged
    case authenticationFailed
    case outcomeUnknown
    case stagingFailed
    case stagingNotADirectory
    case stagingPermissionDenied
}

public struct BrokerFileUploadTicket: Equatable, Sendable {
    public let uploadID: String
    public let capability: String
}

extension BrokerFileUploadTicket: Codable {}

public struct BrokerFileWriteSummary: Equatable, Sendable {
    public let targetID: String
    public let operation: BrokerApprovalOperation
    public let payloadKind: BrokerCatalogPayloadKind
    public let originalFilename: String
    public let byteCount: Int
    public let previousDigest: String?
    public let digest: String
    public let payloadMasked: Bool
    public let state: BrokerRequestState
}

public struct BrokerFrozenFile: Equatable, Sendable {
    public let operationID: String
    public let credentialID: String
    public let targetID: String
    public let operation: BrokerApprovalOperation
    public let previousDigest: String?
    public let originalFilename: String
    public let bytes: Data
    public let byteCount: Int
    public let digest: String
    public let approvalRequestID: String?
    public let approvalCapability: String?

    public var approvalPayloadDigest: String {
        let fields = [operationID, credentialID, targetID, operation.rawValue,
            originalFilename, String(byteCount), previousDigest ?? "none", digest]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public init(
        operationID: String,
        credentialID: String,
        targetID: String,
        operation: BrokerApprovalOperation,
        previousDigest: String?,
        originalFilename: String,
        bytes: Data,
        byteCount: Int,
        digest: String,
        approvalRequestID: String? = nil,
        approvalCapability: String? = nil
    ) {
        self.operationID = operationID
        self.credentialID = credentialID
        self.targetID = targetID
        self.operation = operation
        self.previousDigest = previousDigest
        self.originalFilename = originalFilename
        self.bytes = bytes
        self.byteCount = byteCount
        self.digest = digest
        self.approvalRequestID = approvalRequestID
        self.approvalCapability = approvalCapability
    }
}

/// Freezes Agent-supplied bytes before creating an approval request. Staging
/// files contain only authenticated ciphertext; source paths are never accepted.
public final class BrokerFileWriteCoordinator: @unchecked Sendable {
    public static let maximumByteCount = 5 * 1024 * 1024
    public static let maximumChunkByteCount = 32 * 1024
    public static let maximumUploadSessions = BrokerLimits.maximumPendingApprovalRequests

    private struct Session {
        let operationID: String
        let componentOnly: Bool
        let credentialID: String
        let targetID: String
        let operation: BrokerApprovalOperation
        let originalFilename: String
        let expectedByteCount: Int
        let previousDigest: String?
        let capability: String
        let stagingURL: URL
        let key: SymmetricKey
        var receivedByteCount: Int
        var expiresAt: Date
        var approval: BrokerApprovalTicket?
        var contentDigest: String?
        var approvalDigest: String?
    }

    private let lock = NSLock()
    private let stagingDirectory: URL
    private let authorizeUpload: @Sendable () throws -> Void
    private let approvals: BrokerApprovalStateMachine
    private let authenticateReveal: @Sendable () -> Bool
    private let commitFrozenFile: @Sendable (BrokerFrozenFile) throws -> Void
    private let completedFileCommit: @Sendable (String, String, String) throws -> Bool
    private let submitFrozenApproval: @Sendable (
        String, String?, BrokerApprovalOperationRequest
    ) throws -> BrokerApprovalTicket
    private let normalizeCreateTarget: @Sendable (String) throws -> String
    private let resolvePreviousDigest: @Sendable (String) throws -> String?
    private let clock: @Sendable () -> Date
    private let uploadTTL: TimeInterval
    private var sessions: [String: Session] = [:]
    private struct CompletedUpload {
        let capability: String
        let ticket: BrokerApprovalTicket
    }
    // This is only a reply cache. Eviction cannot repeat a write: the durable
    // request receipt remains authoritative and unknown upload IDs fail closed.
    private var completedUploads: [String: CompletedUpload] = [:]
    private var completedUploadOrder: [String] = []

    public init(
        stagingDirectory: URL,
        approvals: BrokerApprovalStateMachine,
        authenticateReveal: @escaping @Sendable () -> Bool,
        commitFrozenFile: @escaping @Sendable (BrokerFrozenFile) throws -> Void,
        submitFrozenApproval: @escaping @Sendable (
            String, String?, BrokerApprovalOperationRequest
        ) throws -> BrokerApprovalTicket,
        normalizeCreateTarget: @escaping @Sendable (String) throws -> String,
        resolvePreviousDigest: @escaping @Sendable (String) throws -> String? = { _ in nil },
        uploadTTL: TimeInterval = 5 * 60,
        authorizeUpload: @escaping @Sendable () throws -> Void = {},
        clock: @escaping @Sendable () -> Date = { Date() },
        completedFileCommit: @escaping @Sendable (String, String, String) throws -> Bool = { _, _, _ in false }
    ) throws {
        guard uploadTTL.isFinite, uploadTTL > 0 else {
            throw BrokerFileWriteError.invalidRequest
        }
        self.stagingDirectory = stagingDirectory
        self.authorizeUpload = authorizeUpload
        self.approvals = approvals
        self.authenticateReveal = authenticateReveal
        self.commitFrozenFile = commitFrozenFile
        self.completedFileCommit = completedFileCommit
        self.submitFrozenApproval = submitFrozenApproval
        self.normalizeCreateTarget = normalizeCreateTarget
        self.resolvePreviousDigest = resolvePreviousDigest
        self.uploadTTL = uploadTTL
        self.clock = clock
        do {
            try BrokerRuntimeDirectory.prepareStagingDirectory(stagingDirectory)
            for residue in try FileManager.default.contentsOfDirectory(
                at: stagingDirectory,
                includingPropertiesForKeys: nil
            ) where residue.lastPathComponent.hasPrefix("upload-") {
                try FileManager.default.removeItem(at: residue)
            }
        } catch let error as BrokerFileWriteError {
            throw error
        } catch {
            throw BrokerFileWriteError.stagingFailed
        }
    }

    deinit {
        let urls = withLock { sessions.values.map(\.stagingURL) }
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    public func begin(
        operationID: String,
        credentialID: String,
        targetID: String,
        operation: BrokerApprovalOperation,
        originalFilename: String,
        expectedByteCount: Int,
        componentOnly: Bool = false
    ) throws -> BrokerFileUploadTicket {
        try authorizeUpload()
        let boundTargetID = operation == .create
            ? try normalizeCreateTarget(targetID)
            : targetID
        guard Self.validField(operationID), Self.validField(credentialID),
              Self.validField(boundTargetID), Self.validFilename(originalFilename),
              operation == .create || operation == .modify,
              operation == .create || boundTargetID == credentialID,
              expectedByteCount >= 0 else {
            throw BrokerFileWriteError.invalidRequest
        }
        guard expectedByteCount <= Self.maximumByteCount else {
            throw BrokerFileWriteError.tooLarge
        }
        let uploadID = UUID().uuidString
        let capability = UUID().uuidString
        let stagingURL = stagingDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        let key = SymmetricKey(size: .bits256)
        let previousDigest = operation == .modify
            ? try resolvePreviousDigest(credentialID)
            : nil
        guard previousDigest.map(Self.validDigest) ?? true else {
            throw BrokerFileWriteError.invalidRequest
        }
        try writeEncrypted(Data(), key: key, to: stagingURL)
        let session = Session(
            operationID: operationID,
            componentOnly: componentOnly,
            credentialID: credentialID,
            targetID: boundTargetID,
            operation: operation,
            originalFilename: originalFilename,
            expectedByteCount: expectedByteCount,
            previousDigest: previousDigest,
            capability: capability,
            stagingURL: stagingURL,
            key: key,
            receivedByteCount: 0,
            expiresAt: clock().addingTimeInterval(uploadTTL),
            approval: nil,
            contentDigest: nil,
            approvalDigest: nil
        )
        let admitted = withLock {
            purgeExpiredLocked(now: clock())
            guard sessions.count < Self.maximumUploadSessions else { return false }
            sessions[uploadID] = session
            return true
        }
        guard admitted else {
            try? FileManager.default.removeItem(at: stagingURL)
            throw BrokerFileWriteError.capacityReached
        }
        return .init(uploadID: uploadID, capability: capability)
    }

    public func append(
        uploadID: String,
        capability: String,
        offset: Int,
        bytes: Data
    ) throws {
        try authorizeUpload()
        try withLock {
            let now = clock()
            purgeExpiredLocked(now: now)
            guard var session = sessions[uploadID], session.capability == capability else {
                throw BrokerFileWriteError.invalidCapability
            }
            guard session.approval == nil, session.contentDigest == nil else { throw BrokerFileWriteError.alreadyFrozen }
            guard offset == session.receivedByteCount else {
                throw BrokerFileWriteError.outOfOrderChunk
            }
            guard !bytes.isEmpty else { throw BrokerFileWriteError.invalidRequest }
            guard bytes.count <= Self.maximumChunkByteCount,
                  session.receivedByteCount <= session.expectedByteCount - bytes.count else {
                throw BrokerFileWriteError.tooLarge
            }
            var staged = try readEncrypted(session)
            staged.append(bytes)
            try writeEncrypted(staged, key: session.key, to: session.stagingURL)
            session.receivedByteCount = staged.count
            session.expiresAt = now.addingTimeInterval(uploadTTL)
            sessions[uploadID] = session
        }
    }

    public func freeze(
        uploadID: String,
        capability: String
    ) throws -> BrokerApprovalTicket {
        try authorizeUpload()
        return try withLock {
            let now = clock()
            if let completed = completedUploads[uploadID] {
                guard Self.constantTimeEqual(completed.capability, capability) else {
                    throw BrokerFileWriteError.invalidCapability
                }
                return completed.ticket
            }
            purgeExpiredLocked(now: now)
            guard var session = sessions[uploadID], session.capability == capability else {
                throw BrokerFileWriteError.invalidCapability
            }
            guard !session.componentOnly else { throw BrokerFileWriteError.invalidRequest }
            if session.approval != nil, let digest = session.approvalDigest {
                let retried = try approvals.submit(
                    approvalRequest(session: session, digest: digest),
                    trustedCredentialDeadline: .none
                )
                session.approval = retried
                sessions[uploadID] = session
                return retried
            }
            guard session.receivedByteCount == session.expectedByteCount else {
                throw BrokerFileWriteError.truncatedUpload
            }
            let bytes = try readEncrypted(session)
            guard bytes.count == session.expectedByteCount else {
                throw BrokerFileWriteError.truncatedUpload
            }
            let contentDigest = Self.digest(bytes)
            let approvalDigest = Self.approvalDigest(
                session: session,
                contentDigest: contentDigest
            )
            let request = approvalRequest(session: session, digest: approvalDigest)
            let approval = try submitFrozenApproval(
                session.credentialID,
                session.previousDigest,
                request
            )
            session.approval = approval
            session.contentDigest = contentDigest
            session.approvalDigest = approvalDigest
            session.expiresAt = now.addingTimeInterval(uploadTTL)
            sessions[uploadID] = session
            return approval
        }
    }

    public func freezeComponent(uploadID: String, capability: String) throws -> BrokerComponentFileReference {
        try authorizeUpload()
        return try withLock {
            purgeExpiredLocked(now: clock())
            guard var session = sessions[uploadID], session.capability == capability,
                  session.componentOnly else { throw BrokerFileWriteError.invalidCapability }
            if let digest = session.contentDigest {
                return .init(uploadID: uploadID, capability: capability, digest: digest)
            }
            guard session.receivedByteCount == session.expectedByteCount else {
                throw BrokerFileWriteError.truncatedUpload
            }
            let bytes = try readEncrypted(session)
            guard bytes.count == session.expectedByteCount else { throw BrokerFileWriteError.truncatedUpload }
            let digest = Self.digest(bytes)
            session.contentDigest = digest
            session.expiresAt = clock().addingTimeInterval(uploadTTL)
            sessions[uploadID] = session
            return .init(uploadID: uploadID, capability: capability, digest: digest)
        }
    }

    /// App-only: resolve before taking the Vault's agent-operation lease so a
    /// legacy file commit holding this coordinator cannot deadlock on that lease.
    public func resolveComponent(
        _ reference: BrokerComponentFileReference,
        operationID: String
    ) throws -> BrokerFrozenComponentFile {
        try authorizeUpload()
        return try withLock {
            purgeExpiredLocked(now: clock())
            guard let session = sessions[reference.uploadID], session.componentOnly,
                  session.capability == reference.capability,
                  session.operationID == operationID,
                  let digest = session.contentDigest,
                  Self.constantTimeEqual(digest, reference.digest) else {
                throw BrokerFileWriteError.invalidCapability
            }
            let bytes = try readEncrypted(session)
            guard bytes.count == session.expectedByteCount,
                  Self.constantTimeEqual(Self.digest(bytes), digest) else {
                throw BrokerFileWriteError.digestMismatch
            }
            return .init(originalFilename: session.originalFilename, bytes: bytes, digest: digest)
        }
    }

    public func cancelUpload(uploadID: String, capability: String) throws {
        try withLock {
            guard let session = sessions[uploadID], session.capability == capability else {
                throw BrokerFileWriteError.invalidCapability
            }
            if let approval = session.approval {
                _ = try approvals.cancel(requestID: approval.requestID, capability: approval.capability)
            }
            sessions.removeValue(forKey: uploadID)
            do { try FileManager.default.removeItem(at: session.stagingURL) }
            catch { throw BrokerFileWriteError.stagingFailed }
        }
    }

    public func handle(_ request: BrokerFileWriteRequest) throws -> BrokerFileWritePayload {
        switch request {
        case .beginComponent(let request):
            return .upload(try begin(operationID: request.operationID, credentialID: request.operationID,
                targetID: "component", operation: .create, originalFilename: request.originalFilename,
                expectedByteCount: request.expectedByteCount, componentOnly: true))
        case .freezeComponent(let request):
            return .componentFrozen(try freezeComponent(uploadID: request.uploadID, capability: request.capability))
        case .cancelUpload(let request):
            try cancelUpload(uploadID: request.uploadID, capability: request.capability)
            return .uploadCancelled
        case .begin(let request):
            return .upload(try begin(
                operationID: request.operationID,
                credentialID: request.credentialID,
                targetID: request.targetID,
                operation: request.operation,
                originalFilename: request.originalFilename,
                expectedByteCount: request.expectedByteCount
            ))
        case .append(let request):
            try append(
                uploadID: request.uploadID,
                capability: request.capability,
                offset: request.offset,
                bytes: request.bytes
            )
            return .chunkAccepted(nextOffset: request.offset + request.bytes.count)
        case .freeze(let request):
            return .approval(try freeze(
                uploadID: request.uploadID,
                capability: request.capability
            ))
        }
    }

    public func summary(requestID: String) throws -> BrokerFileWriteSummary {
        try withLock {
            purgeExpiredLocked(now: clock())
            guard let session = session(requestID: requestID),
                  let approval = session.approval,
                  let digest = session.contentDigest else {
                throw BrokerFileWriteError.requestNotFound
            }
            let state = try approvals.status(
                requestID: approval.requestID,
                capability: approval.capability
            )
            return .init(
                targetID: session.targetID,
                operation: session.operation,
                payloadKind: .file,
                originalFilename: session.originalFilename,
                byteCount: session.receivedByteCount,
                previousDigest: session.previousDigest,
                digest: digest,
                payloadMasked: true,
                state: state
            )
        }
    }

    public func reveal(requestID: String) throws -> BrokerFrozenFile {
        guard withLock({
            purgeExpiredLocked(now: clock())
            return session(requestID: requestID) != nil
        }) else {
            throw BrokerFileWriteError.requestNotFound
        }
        guard authenticateReveal() else { throw BrokerFileWriteError.authenticationFailed }
        return try withLock {
            purgeExpiredLocked(now: clock())
            guard let session = session(requestID: requestID) else {
                throw BrokerFileWriteError.requestNotFound
            }
            guard let approval = session.approval, let digest = session.approvalDigest else {
                throw BrokerFileWriteError.requestNotFound
            }
            let state = try approvals.status(
                requestID: approval.requestID,
                capability: approval.capability,
                operationRequest: approvalRequest(session: session, digest: digest)
            )
            guard state == .pending || state == .approved else {
                throw BrokerFileWriteError.requestNotFound
            }
            return try frozenFile(session)
        }
    }

    @discardableResult
    public func decide(
        requestID: String,
        capability: String,
        decision: BrokerApprovalDecision
    ) throws -> BrokerApprovalTicket {
        try approvals.decide(
            requestID: requestID,
            capability: capability,
            decision: decision
        )
    }

    public func commit(
        requestID: String,
        capability: String,
        expectedDigest: String
    ) throws {
        try commit(
            requestID: requestID,
            capability: capability,
            expectedDigest: expectedDigest,
            consume: commitFrozenFile
        )
    }

    func commit(
        requestID: String,
        capability: String,
        expectedDigest: String,
        consume: (BrokerFrozenFile) throws -> Void
    ) throws {
        try withLock {
            // A database receipt survives both staging cleanup and a process
            // restart, including the DB-commit -> approval-consumed crash window.
            if try completedFileCommit(requestID, capability, expectedDigest) {
                if let existing = session(requestID: requestID), let digest = existing.approvalDigest,
                   (try? approvals.status(requestID: requestID, capability: capability)) == .approved {
                    _ = try? approvals.consume(requestID: requestID, capability: capability,
                        operationRequest: approvalRequest(session: existing, digest: digest))
                }
                retainCompletedUploads(requestID: requestID)
                return
            }
            purgeExpiredLocked(now: clock())
            guard let match = sessions.first(where: { $0.value.approval?.requestID == requestID }),
                  let approval = match.value.approval,
                  approval.capability == capability,
                  let contentDigest = match.value.contentDigest,
                  let approvalDigest = match.value.approvalDigest else {
                throw BrokerFileWriteError.requestNotFound
            }
            guard Self.constantTimeEqual(contentDigest, expectedDigest) else {
                throw BrokerFileWriteError.digestMismatch
            }
            let currentPreviousDigest = match.value.operation == .modify
                ? try resolvePreviousDigest(match.value.credentialID)
                : nil
            guard currentPreviousDigest.map(Self.validDigest) ?? true else {
                throw BrokerFileWriteError.invalidRequest
            }
            guard Self.equalDigest(currentPreviousDigest, match.value.previousDigest) else {
                throw BrokerFileWriteError.targetChanged
            }
            let file = try frozenFile(match.value)
            do {
                // ponytail: file writes are rare and capped; one lock keeps commit,
                // approval consumption, and replay exclusion linearizable.
                _ = try approvals.consume(
                    requestID: requestID,
                    capability: capability,
                    operationRequest: BrokerApprovalOperationRequest(
                        operationID: match.value.operationID,
                        credentialID: match.value.credentialID,
                        targetID: match.value.targetID,
                        operation: match.value.operation,
                        payloadDigest: approvalDigest
                    ),
                    performing: { try consume(file) }
                )
            } catch let error as BrokerApprovalError {
                throw error
            } catch {
                throw BrokerFileWriteError.outcomeUnknown
            }
            retainCompletedUploads(requestID: requestID)
        }
    }

    private func retainCompletedUploads(requestID: String) {
        let completed = sessions.filter { $0.value.approval?.requestID == requestID }
        for (uploadID, session) in completed {
            guard let approval = session.approval else { continue }
            completedUploads[uploadID] = .init(capability: session.capability,
                ticket: .init(requestID: approval.requestID, capability: approval.capability,
                    state: .consumed, retryCount: approval.retryCount))
            completedUploadOrder.append(uploadID)
            sessions.removeValue(forKey: uploadID)
            try? FileManager.default.removeItem(at: session.stagingURL)
        }
        while completedUploadOrder.count > BrokerLimits.maximumRetainedRequestStates {
            completedUploads.removeValue(forKey: completedUploadOrder.removeFirst())
        }
    }

    private func readEncrypted(_ session: Session) throws -> Data {
        do {
            let combined = try Data(contentsOf: session.stagingURL)
            return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined), using: session.key)
        } catch {
            throw BrokerFileWriteError.stagingFailed
        }
    }

    private func frozenFile(_ session: Session) throws -> BrokerFrozenFile {
        guard let digest = session.contentDigest else {
            throw BrokerFileWriteError.requestNotFound
        }
        let bytes = try readEncrypted(session)
        let actual = Self.digest(bytes)
        guard Self.constantTimeEqual(digest, actual) else {
            throw BrokerFileWriteError.digestMismatch
        }
        return .init(
            operationID: session.operationID,
            credentialID: session.credentialID,
            targetID: session.targetID,
            operation: session.operation,
            previousDigest: session.previousDigest,
            originalFilename: session.originalFilename,
            bytes: bytes,
            byteCount: bytes.count,
            digest: digest,
            approvalRequestID: session.approval?.requestID,
            approvalCapability: session.approval?.capability
        )
    }

    private func approvalRequest(
        session: Session,
        digest: String
    ) -> BrokerApprovalOperationRequest {
        .init(
            operationID: session.operationID,
            credentialID: session.credentialID,
            targetID: session.targetID,
            operation: session.operation,
            payloadDigest: digest
        )
    }

    private func session(requestID: String) -> Session? {
        // ponytail: the approval queue is capped at 64; an extra index adds no value.
        sessions.values.first { $0.approval?.requestID == requestID }
    }

    private func purgeExpiredLocked(now: Date) {
        let expired = sessions.filter { $0.value.expiresAt <= now }
        for (uploadID, session) in expired {
            sessions.removeValue(forKey: uploadID)
            try? FileManager.default.removeItem(at: session.stagingURL)
        }
    }

    private func writeEncrypted(_ data: Data, key: SymmetricKey, to url: URL) throws {
        do {
            let sealed = try ChaChaPoly.seal(data, using: key)
            try sealed.combined.write(to: url, options: .atomic)
            guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
                throw BrokerFileWriteError.stagingFailed
            }
        } catch {
            throw BrokerFileWriteError.stagingFailed
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private static func validField(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= BrokerLimits.maximumFieldBytes
    }

    private static func validFilename(_ value: String) -> Bool {
        validField(value)
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func approvalDigest(session: Session, contentDigest: String) -> String {
        let fields = [
            session.operationID,
            session.credentialID,
            session.targetID,
            session.operation.rawValue,
            session.originalFilename,
            String(session.expectedByteCount),
            session.previousDigest ?? "none",
            contentDigest,
        ]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return digest(Data(canonical.utf8))
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func equalDigest(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return constantTimeEqual(lhs, rhs)
        default: return false
        }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }
    }
}
