import CryptoKit
import Darwin
import Foundation

extension BrokerFileWriteCoordinator {
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
}
