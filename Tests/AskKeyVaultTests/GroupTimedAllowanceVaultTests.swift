import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class GroupTimedAllowanceVaultTests: AgentTextWriteTestSupport {
    func testSnapshotExcludesHiddenRecycledExpiredAndOtherGroupsAndNeverAddsLaterMembers() throws {
        let harness = try makeHarness { _ in true }
        try harness.vault.updateTimedAllowance(enabled: true, minutes: 30)
        let alpha = try create("Alpha", in: harness)
        let beta = try create("Beta", in: harness)
        _ = try create("Allowed", permission: .allowed, in: harness)
        _ = try create("Hidden", permission: .hidden, in: harness)
        _ = try create("Expired", expiry: Date().addingTimeInterval(-60), in: harness)
        let recycled = try create("Recycled", in: harness)
        try harness.vault.deleteTextCredential(id: recycled.id, using: .allow)
        _ = try harness.vault.createTextCredential(.init(name: "Other", value: "synthetic", groupName: "Other"), using: .allow)
        let ticket = try pending("Alpha", in: harness)
        let snapshot = try XCTUnwrap(harness.vault.approvalRequests.pendingRequests().first?.groupAllowanceSnapshot)
        XCTAssertEqual(Set(snapshot.members.map(\.name)), ["Alpha", "Beta", "Allowed"])
        _ = try create("Later", in: harness)
        _ = try harness.vault.decideAgentApproval(requestID: ticket.requestID, capability: ticket.capability,
                                                decision: .timedAllowGroup(duration: 60))
        XCTAssertEqual(harness.vault.approvalRequests.activeTimedAllowances().count, 1)
        XCTAssertNotNil(harness.vault.approvalRequests.timedAllowanceDeadline(credentialID: alpha.id))
        try resolve("Beta", in: harness)
        _ = try pending("Later", in: harness)
        try harness.vault.updateCredentialGroup(id: beta.id, groupName: "Other", using: .allow)
        XCTAssertNil(harness.vault.approvalRequests.timedAllowanceDeadline(credentialID: beta.id))
        XCTAssertNotNil(harness.vault.approvalRequests.timedAllowanceDeadline(credentialID: alpha.id))
        try harness.vault.updateCredentialGroup(id: beta.id, groupName: "Project", using: .allow)
        _ = try pending("Beta", in: harness)
    }

    func testMetadataPermissionAndGroupMutationsRemoveOnlyChangedMember() throws {
        for mutation in ["metadata", "permission", "group"] {
            let harness = try makeHarness { _ in true }
            try harness.vault.updateTimedAllowance(enabled: true, minutes: 30)
            let alpha = try create("Alpha", in: harness)
            let beta = try create("Beta", in: harness)
            let ticket = try pending("Alpha", in: harness)
            _ = try harness.vault.decideAgentApproval(requestID: ticket.requestID, capability: ticket.capability,
                                                    decision: .timedAllowGroup(duration: 60))
            switch mutation {
            case "metadata": try harness.vault.updateCredentialMetadata(id: beta.id, name: "Renamed", usageInstructions: "changed",
                groupName: "Project", permission: .ask, expiresAt: nil, using: .allow)
            case "permission": try harness.vault.updateCredentialPermission(id: beta.id, permission: .hidden, using: .allow)
            default: try harness.vault.updateCredentialGroup(id: beta.id, groupName: nil, using: .allow)
            }
            XCTAssertNil(harness.vault.approvalRequests.timedAllowanceDeadline(credentialID: beta.id), mutation)
            XCTAssertNotNil(harness.vault.approvalRequests.timedAllowanceDeadline(credentialID: alpha.id), mutation)
        }
    }

    func testOtherMemberChangePreservesSingleOptionsAndRequestedChangeCancels() throws {
        for subjectChanged in [false, true] {
            let harness = try makeHarness { _ in true }
            let alpha = try create("Alpha", in: harness)
            let beta = try create("Beta", in: harness)
            let ticket = try pending("Alpha", in: harness)
            try harness.vault.updateCredentialGroup(id: subjectChanged ? alpha.id : beta.id, groupName: nil, using: .allow)
            XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability),
                           subjectChanged ? .cancelled : .pending)
            if !subjectChanged {
                XCTAssertNil(harness.vault.approvalRequests.pendingRequests().first?.groupAllowanceSnapshot)
                _ = try harness.vault.decideAgentApproval(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
            }
        }
    }

    func testPostAuthenticationRevalidationRejectsChangedStoredMemberWithoutCancellingSubject() throws {
        let harness = try makeHarness { _ in true }
        _ = try create("Alpha", in: harness)
        let beta = try create("Beta", in: harness)
        let ticket = try pending("Alpha", in: harness)
        // Bypass mutation callbacks to prove the persisted snapshot is checked again.
        var record = try XCTUnwrap(harness.store.fetchCredential(id: beta.id))
        record.encryptedGroupName = try VaultCrypto.encrypt("Other", using: harness.key)
        try harness.store.updateCredential(record)
        XCTAssertThrowsError(try harness.vault.decideAgentApproval(requestID: ticket.requestID, capability: ticket.capability,
                                                                 decision: .timedAllowGroup(duration: 60)))
        XCTAssertTrue(harness.vault.approvalRequests.activeTimedAllowances().isEmpty)
        XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .pending)
        XCTAssertNil(harness.vault.approvalRequests.pendingRequests().first?.groupAllowanceSnapshot)
        _ = try harness.vault.decideAgentApproval(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
    }

    private func create(_ name: String, permission: CredentialPermission = .ask, expiry: Date? = nil,
                        in harness: Harness) throws -> ManagedTextCredential {
        try harness.vault.createTextCredential(.init(name: name, value: "synthetic-\(name)", groupName: "Project",
            environmentVariable: name.uppercased(), permission: permission, expiresAt: expiry), using: .allow)
    }

    private func pending(_ name: String, in harness: Harness) throws -> BrokerApprovalTicket {
        guard case .approvalRequired(let tickets) = try harness.vault.brokerTextCredentials(for: run(name), cancellation: .init()) else {
            throw BrokerApprovalError.invalidDecision
        }
        return try XCTUnwrap(tickets.first)
    }

    private func resolve(_ name: String, in harness: Harness) throws {
        guard case .resolved(_, _, let lease) = try harness.vault.brokerTextCredentials(for: run(name), cancellation: .init()) else {
            return XCTFail("Expected a snapshot member to be covered")
        }
        lease?.finish(); lease?.cleanup()
    }

    private func run(_ name: String) -> BrokerTextRunRequest {
        .init(operationID: UUID().uuidString, command: ["/usr/bin/true"], credentialNames: [name])
    }
}
