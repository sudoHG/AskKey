import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentAccessTests: XCTestCase {
    func testTextRuntimeWaitsForApprovalThenResolvesTheExactCredentialSet() throws {
        let approvals = BrokerApprovalStateMachine(authenticate: { _ in true })
        let harness = try makeHarness(approvalRequests: approvals)
        try harness.vault.beginManagementSession(using: .allow)
        _ = try harness.vault.createTextCredential(
            .init(name: "ALLOWED", value: "one", environmentVariable: "ONE", permission: .allowed),
            using: .allow
        )
        _ = try harness.vault.createTextCredential(
            .init(name: "ASK", value: "two", environmentVariable: "TWO", permission: .ask),
            using: .allow
        )
        let request = BrokerTextRunRequest(
            operationID: "runtime-operation",
            command: ["/usr/bin/true"],
            credentialNames: ["ALLOWED", "ASK"]
        )

        let first = try harness.vault.brokerTextCredentials(for: request, cancellation: .init())
        guard case .approvalRequired(let tickets) = first, let ticket = tickets.first else {
            return XCTFail("expected one approval ticket")
        }
        XCTAssertEqual(tickets.count, 1)
        _ = try approvals.decide(
            requestID: ticket.requestID,
            capability: ticket.capability,
            decision: .once
        )

        let second = try harness.vault.brokerTextCredentials(for: request, cancellation: .init())
        guard case .resolved(let credentials, let resolvedRequestCount, let lease) = second else {
            return XCTFail("expected resolved credentials")
        }
        XCTAssertEqual(resolvedRequestCount, 2)
        lease?.finish()
        XCTAssertEqual(credentials, [
            .init(environmentVariable: "ONE", value: "one"),
            .init(environmentVariable: "TWO", value: "two"),
        ])
        XCTAssertEqual(
            try approvals.status(requestID: ticket.requestID, capability: ticket.capability),
            .consumed
        )
    }

    func testDeniedAndExpiredRuntimeApprovalsFailWithoutResolvingCredentials() throws {
        for (decision, requestTTL) in [(BrokerApprovalDecision?.some(.deny), 300.0), (nil, 0.02)] {
            let clock = AgentApprovalTestClock(Date())
            let approvals = BrokerApprovalStateMachine(
                requestTTL: requestTTL,
                clock: { clock.now },
                authenticate: { _ in true }
            )
            let harness = try makeHarness(approvalRequests: approvals)
            try harness.vault.beginManagementSession(using: .allow)
            _ = try harness.vault.createTextCredential(
                .init(name: "ASK", value: "must-not-resolve", environmentVariable: "TOKEN", permission: .ask),
                using: .allow
            )
            let request = BrokerTextRunRequest(
                operationID: UUID().uuidString,
                command: ["/usr/bin/true"],
                credentialNames: ["ASK"]
            )
            let first = try harness.vault.brokerTextCredentials(for: request, cancellation: .init())
            guard case .approvalRequired(let tickets) = first, let ticket = tickets.first else {
                return XCTFail("expected approval")
            }
            if let decision {
                _ = try approvals.decide(
                    requestID: ticket.requestID,
                    capability: ticket.capability,
                    decision: decision
                )
            } else {
                clock.now = clock.now.addingTimeInterval(requestTTL)
            }
            XCTAssertThrowsError(
                try harness.vault.brokerTextCredentials(for: request, cancellation: .init())
            ) { error in
                guard case VaultError.credentialUnavailable = error else {
                    return XCTFail("expected non-enumerating refusal, got \(error)")
                }
            }
        }
    }

    func testRevocationCannotCompleteBetweenResolutionAndSpawn() throws {
        for action in ["hide", "delete", "pause"] {
            let harness = try makeHarness()
            try harness.vault.beginManagementSession(using: .allow)
            let credential = try harness.vault.createTextCredential(
                .init(name: "TOKEN", value: "old", environmentVariable: "TOKEN", permission: .allowed),
                using: .allow
            )
            let mutationStarted = DispatchSemaphore(value: 0)
            let mutationFinished = DispatchSemaphore(value: 0)
            let marker = harness.directory.appendingPathComponent("spawned-\(action)")
            let vaultBox = AgentAccessVaultBox(harness.vault)
            let runtime = BrokerTextRuntime(
                resolveCredentials: { request, cancellation in
                    try vaultBox.vault.brokerTextCredentials(for: request, cancellation: cancellation)
                },
                beforeSpawn: {
                    DispatchQueue.global().async {
                        mutationStarted.signal()
                        switch action {
                        case "hide":
                            _ = try? vaultBox.vault.updateTextCredential(
                                id: credential.id,
                                .init(
                                    name: "TOKEN",
                                    value: "new",
                                    environmentVariable: "TOKEN",
                                    permission: .hidden
                                ),
                                using: .allow
                            )
                        case "delete":
                            try? vaultBox.vault.deleteTextCredential(id: credential.id, using: .allow)
                        default:
                            try? vaultBox.vault.pauseAgentAccess(using: .allow)
                        }
                        mutationFinished.signal()
                    }
                    XCTAssertEqual(mutationStarted.wait(timeout: .now() + 1), .success, action)
                    XCTAssertEqual(mutationFinished.wait(timeout: .now() + 0.1), .timedOut, action)
                }
            )

            XCTAssertThrowsError(
                try runtime.run(.init(
                    command: ["/bin/sh", "-c", "printf spawned > '\(marker.path)'"],
                    credentialNames: ["TOKEN"]
                )),
                action
            ) { error in
                XCTAssertEqual(error as? BrokerProviderError, .requestRejected, action)
            }
            XCTAssertEqual(mutationFinished.wait(timeout: .now() + 1), .success, action)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), action)
        }
    }

    func testCredentialExpiryBetweenResolutionAndSpawnPreventsDelivery() throws {
        let harness = try makeHarness()
        try harness.vault.beginManagementSession(using: .allow)
        // Persisted expiries use whole seconds; keep a full setup second.
        let nextWholeSecond = Date().timeIntervalSince1970.rounded(.up)
        let expiresAt = Date(timeIntervalSince1970: nextWholeSecond).addingTimeInterval(1)
        _ = try harness.vault.createTextCredential(
            .init(
                name: "TOKEN",
                value: "old",
                environmentVariable: "TOKEN",
                permission: .allowed,
                expiresAt: expiresAt
            ),
            using: .allow
        )
        let marker = harness.directory.appendingPathComponent("spawned-after-expiry")
        let vaultBox = AgentAccessVaultBox(harness.vault)
        let runtime = BrokerTextRuntime(
            resolveCredentials: { request, cancellation in
                try vaultBox.vault.brokerTextCredentials(for: request, cancellation: cancellation)
            },
            beforeSystemSpawn: {
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while Date() < expiresAt,
                      ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        )

        XCTAssertThrowsError(try runtime.run(.init(
            command: ["/bin/sh", "-c", "printf spawned > '\(marker.path)'"],
            credentialNames: ["TOKEN"]
        ))) { error in
            if !(error is BrokerProviderError) {
                print("Unexpected expiry spawn-boundary error: \(error)")
            }
            XCTAssertEqual(error as? BrokerProviderError, .requestRejected)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testMutationAfterAuthorizationLinearizesAfterSpawn() throws {
        let harness = try makeHarness()
        try harness.vault.beginManagementSession(using: .allow)
        let credential = try harness.vault.createTextCredential(
            .init(name: "TOKEN", value: "old", environmentVariable: "TOKEN", permission: .allowed),
            using: .allow
        )
        let mutationStarted = DispatchSemaphore(value: 0)
        let mutationFinished = DispatchSemaphore(value: 0)
        let output = Pipe()
        let vaultBox = AgentAccessVaultBox(harness.vault)
        let runtime = BrokerTextRuntime(
            resolveCredentials: { request, cancellation in
                try vaultBox.vault.brokerTextCredentials(for: request, cancellation: cancellation)
            },
            afterAuthorization: {
                DispatchQueue.global().async {
                    mutationStarted.signal()
                    _ = try? vaultBox.vault.updateTextCredential(
                        id: credential.id,
                        .init(
                            name: "TOKEN",
                            value: "new",
                            environmentVariable: "TOKEN",
                            permission: .hidden
                        ),
                        using: .allow
                    )
                    mutationFinished.signal()
                }
                XCTAssertEqual(mutationStarted.wait(timeout: .now() + 1), .success)
                XCTAssertEqual(mutationFinished.wait(timeout: .now() + 0.1), .timedOut)
            }
        )

        XCTAssertEqual(
            try runtime.run(
                .init(command: ["/bin/sh", "-c", "printf '%s' \"$TOKEN\""], credentialNames: ["TOKEN"]),
                standardOutputFD: output.fileHandleForWriting.fileDescriptor
            ),
            .exited(0)
        )
        try output.fileHandleForWriting.close()
        XCTAssertEqual(mutationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            "old"
        )
    }


    func testPauseRejectsCatalogAndAgentOperationsUntilVerifiedResume() throws {
        let harness = try makeHarness()
        try harness.vault.beginManagementSession(using: .allow)
        _ = try harness.vault.createTextCredential(
            .init(name: "ALLOWED", value: "secret", permission: .allowed),
            using: .allow
        )
        try harness.vault.pauseAgentAccess(using: .allow)

        XCTAssertThrowsError(try harness.vault.brokerCredentialCatalog()) { error in
            guard case VaultError.agentAccessPaused = error else {
                return XCTFail("expected paused catalog, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try harness.vault.authorizeAgentCredential(
                named: "ALLOWED", operation: .read, caller: .init(name: "Codex")
            )
        ) { error in
            guard case VaultError.agentAccessPaused = error else {
                return XCTFail("expected paused operation, got \(error)")
            }
        }

        try harness.vault.resumeAgentAccess(using: .allow)
        XCTAssertEqual(try harness.vault.brokerCredentialCatalog().map(\.name), ["ALLOWED"])
        XCTAssertEqual(
            try harness.vault.authorizeAgentCredential(
                named: "ALLOWED", operation: .read, caller: .init(name: "Codex")
            ),
            .allowed
        )
    }

    func testEmergencyPauseDoesNotRequireAManagementSession() throws {
        let harness = try makeHarness()
        try harness.vault.pauseAgentAccess(using: .allow)

        XCTAssertTrue(try harness.vault.isAgentAccessPaused())
        XCTAssertFalse(harness.vault.hasActiveManagementSession)
        XCTAssertThrowsError(try harness.vault.brokerCredentialCatalog()) { error in
            guard case VaultError.agentAccessPaused = error else {
                return XCTFail("expected paused catalog, got \(error)")
            }
        }
    }

    func testResumeWithoutManagementSessionRequiresAuthAndDoesNotOpenASession() throws {
        let harness = try makeHarness()
        try harness.vault.pauseAgentAccess(using: .allow)
        XCTAssertThrowsError(try harness.vault.resumeAgentAccess(using: .deny)) { error in
            guard case VaultError.managementAuthenticationRequired = error else {
                return XCTFail("expected fresh system authentication, got \(error)")
            }
        }
        XCTAssertTrue(try harness.vault.isAgentAccessPaused())
        XCTAssertFalse(harness.vault.hasActiveManagementSession)

        try harness.vault.resumeAgentAccess(using: .allow)
        XCTAssertFalse(try harness.vault.isAgentAccessPaused())
        XCTAssertFalse(harness.vault.hasActiveManagementSession)
        XCTAssertEqual(try harness.vault.brokerCredentialCatalog(), [])
    }

    func testPausePersistsAcrossRestartAndResumeRequiresFreshAuthentication() throws {
        let directory = try makeDirectory()
        let databasePath = directory.appendingPathComponent("vault.db").path
        let key = VaultCrypto.generateKey()
        let firstStore = try VaultStore(path: databasePath)
        let firstVault = Vault(store: firstStore, key: key)
        try firstVault.beginManagementSession(using: .allow)

        try firstVault.pauseAgentAccess(using: .allow)
        XCTAssertTrue(try firstVault.isAgentAccessPaused())
        try firstStore.close()

        let restartedVault = Vault(store: try VaultStore(path: databasePath), key: key)
        XCTAssertTrue(try restartedVault.isAgentAccessPaused())
        try restartedVault.beginManagementSession(using: .allow)
        XCTAssertThrowsError(try restartedVault.resumeAgentAccess(using: .deny)) { error in
            guard case VaultError.managementAuthenticationRequired = error else {
                return XCTFail("expected fresh system authentication, got \(error)")
            }
        }
        XCTAssertTrue(try restartedVault.isAgentAccessPaused())

        try restartedVault.resumeAgentAccess(using: .allow)
        XCTAssertFalse(try restartedVault.isAgentAccessPaused())
    }

    func testPauseCancelsPendingBrokerRequests() throws {
        let harness = try makeHarness()
        try harness.vault.beginManagementSession(using: .allow)
        try harness.vault.brokerRequests.register(requestID: "pending", capability: "capability")

        try harness.vault.pauseAgentAccess(using: .allow)

        XCTAssertEqual(
            harness.vault.brokerRequests.status(requestID: "pending", capability: "capability"),
            .cancelled
        )
    }

    func testPauseAndCredentialMutationRevokeVNextApprovalOperations() throws {
        let harness = try makeHarness()
        try harness.vault.beginManagementSession(using: .allow)
        let credential = try harness.vault.createTextCredential(
            .init(name: "TOKEN", value: "old", permission: .ask),
            using: .allow
        )
        let mutation = try harness.vault.approvalRequests.submit(
            .init(
                operationID: "mutation",
                credentialID: credential.id,
                targetID: credential.id,
                operation: .modify,
                payloadDigest: String(repeating: "a", count: 64)
            ),
            trustedCredentialDeadline: .none
        )

        _ = try harness.vault.updateTextCredential(
            id: credential.id,
            .init(name: "TOKEN", value: "new", permission: .ask),
            using: .allow
        )
        XCTAssertEqual(
            try harness.vault.approvalRequests.status(
                requestID: mutation.requestID,
                capability: mutation.capability
            ),
            .cancelled
        )

        let read = try harness.vault.approvalRequests.submit(
            .init(
                operationID: "read",
                credentialID: credential.id,
                targetID: credential.id,
                operation: .read,
                payloadDigest: String(repeating: "b", count: 64)
            ),
            trustedCredentialDeadline: .none
        )
        try harness.vault.pauseAgentAccess(using: .allow)
        XCTAssertEqual(
            try harness.vault.approvalRequests.status(
                requestID: read.requestID,
                capability: read.capability
            ),
            .cancelled
        )
    }

    func testCredentialExpiryIsTheApprovalOperationDeadline() throws {
        let clock = AgentApprovalTestClock(Date(timeIntervalSince1970: 0))
        let approvals = BrokerApprovalStateMachine(clock: { clock.now })
        let harness = try makeHarness(approvalRequests: approvals)
        try harness.vault.beginManagementSession(using: .allow)
        let credential = try harness.vault.createTextCredential(
            .init(
                name: "EXPIRING",
                value: "value",
                permission: .ask,
                expiresAt: Date(timeIntervalSince1970: 1)
            ),
            using: .allow
        )
        let approval = try harness.vault.approvalRequests.submit(
            .init(
                operationID: "expiring-read",
                credentialID: credential.id,
                targetID: credential.id,
                operation: .read,
                payloadDigest: String(repeating: "c", count: 64)
            ),
            trustedCredentialDeadline: .expiresAt(Date(timeIntervalSince1970: 1))
        )
        clock.now = Date(timeIntervalSince1970: 2)

        XCTAssertEqual(
            try harness.vault.approvalRequests.status(
                requestID: approval.requestID,
                capability: approval.capability
            ),
            .expired
        )
    }

    func testCredentialChangeAndDeletionRevokePendingRequests() throws {
        let harness = try makeHarness()
        try harness.vault.beginManagementSession(using: .allow)
        let credential = try harness.vault.createTextCredential(
            .init(name: "TOKEN", value: "old", permission: .allowed),
            using: .allow
        )
        try harness.vault.brokerRequests.register(
            requestID: "update", capability: "cap-1", credentialID: credential.id
        )
        try harness.vault.brokerRequests.register(
            requestID: "unrelated", capability: "cap-other", credentialID: "another-credential"
        )

        _ = try harness.vault.updateTextCredential(
            id: credential.id,
            .init(name: "TOKEN", value: "new", permission: .hidden),
            using: .allow
        )
        XCTAssertEqual(
            harness.vault.brokerRequests.status(requestID: "update", capability: "cap-1"),
            .cancelled
        )
        XCTAssertEqual(
            harness.vault.brokerRequests.status(requestID: "unrelated", capability: "cap-other"),
            .pending
        )

        try harness.vault.brokerRequests.register(
            requestID: "delete", capability: "cap-2", credentialID: credential.id
        )
        try harness.vault.deleteTextCredential(id: credential.id, using: .allow)
        XCTAssertEqual(
            harness.vault.brokerRequests.status(requestID: "delete", capability: "cap-2"),
            .cancelled
        )
        XCTAssertEqual(
            harness.vault.brokerRequests.status(requestID: "unrelated", capability: "cap-other"),
            .pending
        )
    }

    func testPermissionsExpiryAndCallerClaimsProduceTheSpecifiedReadResult() throws {
        let harness = try makeHarness()
        try harness.vault.beginManagementSession(using: .allow)
        for (name, permission, expiresAt) in [
            ("ALLOWED", CredentialPermission.allowed, nil),
            ("ASK", .ask, nil),
            ("HIDDEN", .hidden, nil),
            ("EXPIRED", .allowed, Date(timeIntervalSince1970: 1)),
        ] {
            _ = try harness.vault.createTextCredential(
                .init(name: name, value: "secret", permission: permission, expiresAt: expiresAt),
                using: .allow
            )
        }
        harness.vault.endManagementSession()

        let claims = [
            BrokerCallerClaim(name: "Codex", path: "/Applications/Codex", signature: "signed"),
            BrokerCallerClaim(name: "Impostor", path: "/tmp/codex", signature: "forged"),
        ]
        for claim in claims {
            XCTAssertEqual(
                try harness.vault.authorizeAgentCredential(
                    named: "ALLOWED", operation: .read, caller: claim,
                    now: Date(timeIntervalSince1970: 2)
                ),
                .allowed
            )
            XCTAssertEqual(
                try harness.vault.authorizeAgentCredential(
                    named: "ASK", operation: .read, caller: claim,
                    now: Date(timeIntervalSince1970: 2)
                ),
                .requiresApproval
            )
            for operation in [AgentCredentialOperation.modify, .delete] {
                XCTAssertEqual(
                    try harness.vault.authorizeAgentCredential(
                        named: "ALLOWED", operation: operation, caller: claim,
                        now: Date(timeIntervalSince1970: 2)
                    ),
                    .requiresApproval
                )
            }
        }

        for unavailableName in ["HIDDEN", "MISSING", "EXPIRED"] {
            for operation in [AgentCredentialOperation.read, .modify, .delete] {
                XCTAssertThrowsError(
                    try harness.vault.authorizeAgentCredential(
                        named: unavailableName, operation: operation, caller: claims[0],
                        now: Date(timeIntervalSince1970: 2)
                    )
                ) { error in
                    guard case VaultError.credentialUnavailable = error else {
                        return XCTFail("expected one non-enumerating error, got \(error)")
                    }
                    XCTAssertFalse(error.localizedDescription.contains(unavailableName))
                }
            }
        }
    }

    private func makeHarness(
        approvalRequests: BrokerApprovalStateMachine = BrokerApprovalStateMachine()
    ) throws -> (vault: Vault, directory: URL) {
        let directory = try makeDirectory()
        return (
            Vault(
                store: try VaultStore(path: directory.appendingPathComponent("vault.db").path),
                key: VaultCrypto.generateKey(),
                approvalRequests: approvalRequests
            ),
            directory
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyAgentAccessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private final class AgentApprovalTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

private final class AgentAccessVaultBox: @unchecked Sendable {
    let vault: Vault
    init(_ vault: Vault) { self.vault = vault }
}
