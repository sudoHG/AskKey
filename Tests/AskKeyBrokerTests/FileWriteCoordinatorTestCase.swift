import Foundation
import XCTest
@testable import AskKeyBroker

class FileWriteCoordinatorTestCase: XCTestCase {
    func begin(
        _ harness: Harness,
        operationID: String,
        expectedByteCount: Int
    ) throws -> BrokerFileUploadTicket {
        try harness.coordinator.begin(
            operationID: operationID,
            credentialID: "credential-id",
            targetID: "credential-id",
            operation: .modify,
            originalFilename: "AuthKey.p8",
            expectedByteCount: expectedByteCount
        )
    }

    func makeCoordinator(stagingDirectory: URL) throws -> BrokerFileWriteCoordinator {
        try BrokerFileWriteCoordinator(
            stagingDirectory: stagingDirectory,
            approvals: BrokerApprovalStateMachine(authenticate: { _ in true }),
            authenticateReveal: { true },
            commitFrozenFile: { _ in },
            submitFrozenApproval: { _, _, request in
                try BrokerApprovalStateMachine(authenticate: { _ in true })
                    .submit(request, trustedCredentialDeadline: .none)
            },
            normalizeCreateTarget: { $0 }
        )
    }

    func makeHarness(
        authenticateReveal: @escaping @Sendable () -> Bool = { true },
        commitFrozenFile: @escaping @Sendable (BrokerFrozenFile) throws -> Void = { _ in },
        submitFrozenApproval: (@Sendable (
            String, String?, BrokerApprovalOperationRequest
        ) throws -> BrokerApprovalTicket)? = nil,
        normalizeCreateTarget: @escaping @Sendable (String) throws -> String = { $0 },
        resolvePreviousDigest: @escaping @Sendable (String) throws -> String? = { _ in nil },
        uploadTTL: TimeInterval = 5 * 60,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyFileWriteTests-\(UUID().uuidString)", isDirectory: true)
        let approvals = BrokerApprovalStateMachine(authenticate: { _ in true })
        let submit = submitFrozenApproval ?? { credentialID, expectedDigest, request in
            let currentDigest = request.operation == .modify
                ? try resolvePreviousDigest(credentialID)
                : nil
            guard currentDigest == expectedDigest else {
                throw BrokerFileWriteError.targetChanged
            }
            return try approvals.submit(request, trustedCredentialDeadline: .none)
        }
        let coordinator = try BrokerFileWriteCoordinator(
            stagingDirectory: directory,
            approvals: approvals,
            authenticateReveal: authenticateReveal,
            commitFrozenFile: commitFrozenFile,
            submitFrozenApproval: submit,
            normalizeCreateTarget: normalizeCreateTarget,
            resolvePreviousDigest: resolvePreviousDigest,
            uploadTTL: uploadTTL,
            clock: clock
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return Harness(coordinator: coordinator, approvals: approvals, directory: directory)
    }
}
