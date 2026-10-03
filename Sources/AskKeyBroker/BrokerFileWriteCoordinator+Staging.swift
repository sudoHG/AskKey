import CryptoKit
import Darwin
import Foundation

extension BrokerFileWriteCoordinator {
    func readEncrypted(_ session: Session) throws -> Data {
        do {
            let combined = try Data(contentsOf: session.stagingURL)
            return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined), using: session.key)
        } catch {
            throw BrokerFileWriteError.stagingFailed
        }
    }

    func frozenFile(_ session: Session) throws -> BrokerFrozenFile {
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

    func approvalRequest(
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

    func session(requestID: String) -> Session? {
        // ponytail: the approval queue is capped at 64; an extra index adds no value.
        sessions.values.first { $0.approval?.requestID == requestID }
    }

    func purgeExpiredLocked(now: Date) {
        let expired = sessions.filter { $0.value.expiresAt <= now }
        for (uploadID, session) in expired {
            sessions.removeValue(forKey: uploadID)
            try? FileManager.default.removeItem(at: session.stagingURL)
        }
    }

    func writeEncrypted(_ data: Data, key: SymmetricKey, to url: URL) throws {
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

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}
