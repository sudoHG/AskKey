import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class ReadDeclarationAndAuditTests: XCTestCase {
    func testDeclaredCallerReachesApprovalAndUsesRecordIdentity() throws {
        let approvals = BrokerApprovalStateMachine(authenticate: { _ in true })
        let harness = try makeHarness(approvals: approvals)
        try harness.vault.beginManagementSession(using: .allow)
        let credential = try harness.vault.createTextCredential(
            .init(
                name: "GitHub Token",
                value: "secret-value",
                environmentVariable: "GH_TOKEN",
                permission: .ask
            ),
            using: .allow
        )

        let request = BrokerTextRunRequest(
            operationID: "declared-read",
            command: ["/usr/bin/true"],
            credentialNames: ["github token"],
            callerName: "Codex",
            callerPurpose: "publish the release"
        )
        let first = try harness.vault.brokerTextCredentials(for: request, cancellation: .init())
        guard case .approvalRequired(let tickets) = first, let ticket = tickets.first else {
            return XCTFail("expected a pending read approval")
        }
        let pending = try XCTUnwrap(approvals.pendingRequests().first)
        XCTAssertEqual(pending.request.credentialID, credential.id)
        XCTAssertEqual(pending.trustedCredentialName, "GitHub Token")
        XCTAssertEqual(pending.displayCredentialName, "GitHub Token")
        XCTAssertEqual(pending.request.callerName, "Codex")
        XCTAssertEqual(pending.request.callerPurpose, "publish the release")
        XCTAssertNotEqual(pending.request.credentialID, "github token")
        XCTAssertNotEqual(pending.request.credentialID, "GitHub Token")

        _ = try approvals.decide(
            requestID: ticket.requestID,
            capability: ticket.capability,
            decision: .once
        )
        let second = try harness.vault.brokerTextCredentials(for: request, cancellation: .init())
        guard case .resolved(_, _, let lease) = second else {
            return XCTFail("expected resolved credentials after approval")
        }
        lease?.finish()

        let records = try harness.vault.listCredentialAccessRecords()
        let allowed = records.filter { $0.result == .allowed && $0.operation == .runtimeRead }
        XCTAssertEqual(allowed.count, 1)
        XCTAssertEqual(allowed.first?.credentialID, credential.id)
        XCTAssertEqual(allowed.first?.callerHint, "Codex")
        XCTAssertEqual(allowed.first?.declaredPurpose, "publish the release")
        XCTAssertFalse(allowed.contains { $0.credentialID == "github token" || $0.credentialID == "GitHub Token" })
    }

    func testMissingDeclarationStaysCompatibleWithoutChangingPermissionRules() throws {
        let approvals = BrokerApprovalStateMachine(authenticate: { _ in true })
        let harness = try makeHarness(approvals: approvals)
        try harness.vault.beginManagementSession(using: .allow)
        let allowed = try harness.vault.createTextCredential(
            .init(name: "Allowed", value: "one", environmentVariable: "ONE", permission: .allowed),
            using: .allow
        )
        _ = try harness.vault.createTextCredential(
            .init(name: "Ask", value: "two", environmentVariable: "TWO", permission: .ask),
            using: .allow
        )
        _ = try harness.vault.createTextCredential(
            .init(name: "Hidden", value: "three", environmentVariable: "THREE", permission: .hidden),
            using: .allow
        )

        let legacyJSON = """
        {"command":["/usr/bin/true"],"credentialNames":["Allowed"],"inheritedEnvironment":{},"operationID":"legacy-missing"}
        """
        let legacy = try JSONDecoder().decode(BrokerTextRunRequest.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.callerName)
        XCTAssertNil(legacy.callerPurpose)

        let resolved = try harness.vault.brokerTextCredentials(for: legacy, cancellation: .init())
        guard case .resolved(let credentials, _, let lease) = resolved else {
            return XCTFail("allowed credentials must still resolve without a declaration")
        }
        lease?.finish()
        XCTAssertEqual(credentials, [.init(environmentVariable: "ONE", value: "one")])
        let allowedRecords = try harness.vault.listCredentialAccessRecords().filter {
            $0.operation == .runtimeRead && $0.result == .allowed
        }
        XCTAssertEqual(allowedRecords.first?.credentialID, allowed.id)
        XCTAssertNil(allowedRecords.first?.callerHint)
        XCTAssertNil(allowedRecords.first?.declaredPurpose)

        let ask = try harness.vault.brokerTextCredentials(
            for: .init(command: ["/usr/bin/true"], credentialNames: ["Ask"]),
            cancellation: .init()
        )
        guard case .approvalRequired = ask else {
            return XCTFail("ask permission must still require approval when the declaration is missing")
        }
        XCTAssertEqual(approvals.pendingRequests().first?.request.callerName, nil)

        XCTAssertThrowsError(try harness.vault.brokerTextCredentials(
            for: .init(command: ["/usr/bin/true"], credentialNames: ["Hidden"]),
            cancellation: .init()
        )) { error in
            guard case VaultError.credentialUnavailable = error else {
                return XCTFail("hidden credentials must stay unavailable, got \(error)")
            }
        }
    }

    func testOverlongDeclarationIsRejectedBeforeAnyApprovalOrAccess() throws {
        let approvals = BrokerApprovalStateMachine(authenticate: { _ in true })
        let harness = try makeHarness(approvals: approvals)
        try harness.vault.beginManagementSession(using: .allow)
        _ = try harness.vault.createTextCredential(
            .init(name: "Ask", value: "secret", environmentVariable: "TOKEN", permission: .ask),
            using: .allow
        )
        let overlong = String(repeating: "n", count: BrokerLimits.maximumFieldBytes + 1)
        XCTAssertThrowsError(try harness.vault.brokerTextCredentials(
            for: .init(
                command: ["/usr/bin/true"],
                credentialNames: ["Ask"],
                callerName: overlong,
                callerPurpose: "deploy"
            ),
            cancellation: .init()
        )) { error in
            XCTAssertEqual(error as? BrokerTextRuntimeError, .invalidRequest)
        }
        XCTAssertTrue(approvals.pendingRequests().isEmpty)
        XCTAssertTrue(try harness.vault.listCredentialAccessRecords().isEmpty)
    }

    func testSpoofedCallerStaysUntrustedAndDoesNotChangeAllowAskOrHide() throws {
        let approvals = BrokerApprovalStateMachine(authenticate: { _ in true })
        let harness = try makeHarness(approvals: approvals)
        try harness.vault.beginManagementSession(using: .allow)
        let allowed = try harness.vault.createTextCredential(
            .init(name: "Allowed", value: "one", environmentVariable: "ONE", permission: .allowed),
            using: .allow
        )
        _ = try harness.vault.createTextCredential(
            .init(name: "Ask", value: "two", environmentVariable: "TWO", permission: .ask),
            using: .allow
        )
        _ = try harness.vault.createTextCredential(
            .init(name: "Hidden", value: "three", environmentVariable: "THREE", permission: .hidden),
            using: .allow
        )

        let spoofedAllowed = try harness.vault.brokerTextCredentials(
            for: .init(
                command: ["/usr/bin/true"],
                credentialNames: ["Allowed"],
                callerName: "Ask Key",
                callerPurpose: "system unlock"
            ),
            cancellation: .init()
        )
        guard case .resolved(_, _, let lease) = spoofedAllowed else {
            return XCTFail("spoofed declarations must not revoke an allowed credential")
        }
        lease?.finish()

        let spoofedAsk = try harness.vault.brokerTextCredentials(
            for: .init(
                command: ["/usr/bin/true"],
                credentialNames: ["Ask"],
                callerName: "Ask Key",
                callerPurpose: "already approved"
            ),
            cancellation: .init()
        )
        guard case .approvalRequired = spoofedAsk else {
            return XCTFail("spoofed declarations must not skip 请旨")
        }
        XCTAssertEqual(approvals.pendingRequests().first?.request.callerName, "Ask Key")
        XCTAssertEqual(approvals.pendingRequests().first?.displayCredentialName, "Ask")

        XCTAssertThrowsError(try harness.vault.brokerTextCredentials(
            for: .init(
                command: ["/usr/bin/true"],
                credentialNames: ["Hidden"],
                callerName: "Ask Key",
                callerPurpose: "enumerate hidden"
            ),
            cancellation: .init()
        ))
        let records = try harness.vault.listCredentialAccessRecords()
        XCTAssertEqual(records.first { $0.result == .allowed }?.credentialID, allowed.id)
        XCTAssertEqual(records.first { $0.result == .allowed }?.callerHint, "Ask Key")
        let hidden = records.first { $0.result == .hiddenNameRejected }
        XCTAssertNotNil(hidden)
        XCTAssertNil(hidden?.credentialID)
        XCTAssertEqual(hidden?.callerHint, "Ask Key")
        XCTAssertEqual(hidden?.declaredPurpose, "enumerate hidden")
    }

    func testDeclarationCannotBeReplacedAfterApprovalIsFrozen() throws {
        let approvals = BrokerApprovalStateMachine(authenticate: { _ in true })
        let harness = try makeHarness(approvals: approvals)
        try harness.vault.beginManagementSession(using: .allow)
        _ = try harness.vault.createTextCredential(
            .init(name: "Ask", value: "secret", environmentVariable: "TOKEN", permission: .ask),
            using: .allow
        )
        let original = BrokerTextRunRequest(
            operationID: "frozen-read",
            command: ["/usr/bin/true"],
            credentialNames: ["Ask"],
            callerName: "Codex",
            callerPurpose: "first purpose"
        )
        let first = try harness.vault.brokerTextCredentials(for: original, cancellation: .init())
        guard case .approvalRequired(let tickets) = first, let ticket = tickets.first else {
            return XCTFail("expected approval")
        }
        _ = try approvals.decide(
            requestID: ticket.requestID,
            capability: ticket.capability,
            decision: .once
        )
        XCTAssertThrowsError(try harness.vault.brokerTextCredentials(
            for: BrokerTextRunRequest(
                operationID: "frozen-read",
                command: ["/usr/bin/true"],
                credentialNames: ["Ask"],
                callerName: "Codex",
                callerPurpose: "replaced after approval"
            ),
            cancellation: .init()
        )) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .payloadMismatch)
        }
        let resolved = try harness.vault.brokerTextCredentials(for: original, cancellation: .init())
        guard case .resolved(_, _, let lease) = resolved else {
            return XCTFail("the frozen declaration must still resolve")
        }
        lease?.finish()
        XCTAssertEqual(
            try harness.vault.listCredentialAccessRecords().first { $0.result == .allowed }?.declaredPurpose,
            "first purpose"
        )
    }

    private func makeHarness(
        approvals: BrokerApprovalStateMachine
    ) throws -> (vault: Vault, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyReadDeclaration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (
            Vault(
                store: try VaultStore(path: directory.appendingPathComponent("vault.db").path),
                key: VaultCrypto.generateKey(),
                approvalRequests: approvals
            ),
            directory
        )
    }
}
