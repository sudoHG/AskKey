import CryptoKit
import Darwin
import Foundation

/// Freezes Agent-supplied bytes before creating an approval request. Staging
/// files contain only authenticated ciphertext; source paths are never accepted.
public final class BrokerFileWriteCoordinator: @unchecked Sendable {
    public static let maximumByteCount = 5 * 1024 * 1024
    public static let maximumChunkByteCount = 32 * 1024
    public static let maximumUploadSessions = BrokerLimits.maximumPendingApprovalRequests

    struct Session {
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

    let lock = NSLock()
    let stagingDirectory: URL
    let authorizeUpload: @Sendable () throws -> Void
    let approvals: BrokerApprovalStateMachine
    let authenticateReveal: @Sendable () -> Bool
    let commitFrozenFile: @Sendable (BrokerFrozenFile) throws -> Void
    let completedFileCommit: @Sendable (String, String, String) throws -> Bool
    let submitFrozenApproval: @Sendable (
        String, String?, BrokerApprovalOperationRequest
    ) throws -> BrokerApprovalTicket
    let normalizeCreateTarget: @Sendable (String) throws -> String
    let resolvePreviousDigest: @Sendable (String) throws -> String?
    let clock: @Sendable () -> Date
    let uploadTTL: TimeInterval
    var sessions: [String: Session] = [:]
    struct CompletedUpload {
        let capability: String
        let ticket: BrokerApprovalTicket
    }
    // This is only a reply cache. Eviction cannot repeat a write: the durable
    // request receipt remains authoritative and unknown upload IDs fail closed.
    var completedUploads: [String: CompletedUpload] = [:]
    var completedUploadOrder: [String] = []

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

}
