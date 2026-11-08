import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

/// An import is a management change like creating credentials in the App:
/// it leaves approvals and timed allowances alone, and only a pending request
/// whose frozen state it changes fails at commit.
final class BackupImportApprovalTests: AgentOrganizationTestSupport {
    func testUnrelatedApprovalsAndTimedAllowancesSurviveAndChangedRequestsAreRefusedAtCommit() throws {
        let harness = try makeHarness { _ in true }
        try harness.vault.updateTimedAllowance(enabled: true, minutes: 30)
        let alpha = try member("Alpha", group: "Project", harness: harness)
        let beta = try member("Beta", group: "Project", harness: harness)
        _ = try member("Gamma", group: nil, harness: harness)

        // A timed allowance for the Project group, and a pending read of Gamma.
        let alphaTicket = try pendingRead("Alpha", harness: harness)
        _ = try harness.vault.decideAgentApproval(requestID: alphaTicket.requestID, capability: alphaTicket.capability,
                                                decision: .timedAllowGroup(duration: 60))
        let gammaTicket = try pendingRead("Gamma", harness: harness)
        // Approved agent writes waiting for commit: one names the Project
        // group, one creates the name the import takes, one is unrelated.
        let organize = request([.move(credential: "Gamma", group: "Project")])
        let organizeTicket = try approve(organize, harness: harness)
        let create = AgentTextWriteRequest(operationID: UUID().uuidString,
                                           action: .create(name: "Imported Member", value: "synthetic-agent-value"))
        let createTicket = try approve(create, harness: harness)
        let unrelated = request([.createGroup("Unrelated")])
        let unrelatedTicket = try approve(unrelated, harness: harness)

        let source = try AgentAccessPolicyLibrary()
        addTeardownBlock { try? source.close() }
        _ = try source.vault.createTextCredential(.init(name: "Imported Member", value: "synthetic-imported",
                                                        groupName: "project", permission: .allowed), using: .allow)
        try source.vault.beginManagementSession(using: .allow)
        let export = try source.vault.exportBackup(using: .allow)
        let plan = try harness.vault.planBackupImport(export.fileBytes, recoveryKey: export.recoveryKey.groupedText,
                                                      renameSuffix: backupRenameSuffix)
        XCTAssertEqual(plan.createdGroups, [])
        _ = try harness.vault.commitBackupImport(plan, using: .allow)
        // The new member joins the existing spelling of the group.
        let imported = try XCTUnwrap(harness.vault.listTextCredentials().first { $0.name == "Imported Member" })
        XCTAssertEqual(imported.groupName, "Project")
        XCTAssertEqual(imported.permission, .ask)

        XCTAssertNotNil(harness.vault.approvalRequests.timedAllowanceDeadline(credentialID: alpha.id))
        XCTAssertNotNil(harness.vault.approvalRequests.timedAllowanceDeadline(credentialID: beta.id))
        try resolveRead("Beta", harness: harness)
        XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: gammaTicket.requestID,
                                                               capability: gammaTicket.capability), .pending)
        _ = try harness.vault.decideAgentApproval(requestID: gammaTicket.requestID, capability: gammaTicket.capability,
                                                decision: .once)
        XCTAssertThrowsError(try commit(organize, harness: harness, ticket: organizeTicket)) { error in
            guard case VaultError.credentialChanged = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try commit(create, harness: harness, ticket: createTicket)) { error in
            guard case VaultError.agentWriteNameUnavailable = error else { return XCTFail("\(error)") }
        }
        _ = try commit(unrelated, harness: harness, ticket: unrelatedTicket)
        XCTAssertTrue(try harness.vault.listCredentialGroups().contains("Unrelated"))
        XCTAssertNil(try group(try XCTUnwrap(harness.vault.listTextCredentials().first { $0.name == "Gamma" }).id,
                               harness: harness))
    }

    private func member(_ name: String, group: String?, harness: Harness) throws -> ManagedTextCredential {
        try harness.vault.createTextCredential(.init(name: name, value: "synthetic-\(name)", groupName: group,
            environmentVariable: name.uppercased()), using: .allow)
    }

    private func pendingRead(_ name: String, harness: Harness) throws -> BrokerApprovalTicket {
        guard case .approvalRequired(let tickets) = try harness.vault.brokerTextCredentials(for: run(name),
                                                                                          cancellation: .init()) else {
            throw BrokerApprovalError.invalidDecision
        }
        return try XCTUnwrap(tickets.first)
    }

    private func resolveRead(_ name: String, harness: Harness) throws {
        guard case .resolved(_, _, let lease) = try harness.vault.brokerTextCredentials(for: run(name),
                                                                                      cancellation: .init()) else {
            return XCTFail("Expected \(name) to be covered by the timed allowance")
        }
        lease?.finish(); lease?.cleanup()
    }

    private func run(_ name: String) -> BrokerTextRunRequest {
        .init(operationID: UUID().uuidString, command: ["/usr/bin/true"], credentialNames: [name])
    }
}
