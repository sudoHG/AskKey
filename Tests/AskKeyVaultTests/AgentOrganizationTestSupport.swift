import XCTest
import AskKeyBroker
@testable import AskKeyVault

class AgentOrganizationTestSupport: AgentTextWriteTestSupport {
    func request(_ operations: [BrokerOrganizationOperation], id: String = UUID().uuidString) -> AgentTextWriteRequest {
        .init(operationID: id, action: .organize(operations), callerName: "Synthetic Agent", callerPurpose: "Organize synthetic fixtures")
    }

    func approve(_ request: AgentTextWriteRequest, harness: Harness) throws -> AgentTextWriteSubmission {
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        XCTAssertEqual(ticket.state, .pending)
        _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        return ticket
    }

    func commit(_ request: AgentTextWriteRequest, harness: Harness, ticket: AgentTextWriteSubmission) throws -> AgentTextWriteResult {
        try harness.vault.commitAgentTextWrite(request, requestID: ticket.requestID, capability: ticket.capability)
    }

    func group(_ id: String, harness: Harness) throws -> String? {
        try harness.store.fetchAllCredentialsIncludingRecycled().first { $0.id == id }?
            .encryptedGroupName.map { try VaultCrypto.decrypt($0, using: harness.key) }
    }

    @discardableResult
    func credential(_ name: String, group: String? = nil, permission: CredentialPermission = .ask,
                    expiresAt: Date? = nil, harness: Harness) throws -> ManagedTextCredential {
        try harness.vault.createTextCredential(.init(name: name, value: "synthetic-" + name,
            usageInstructions: "Synthetic guidance", privateNotes: "synthetic-private", groupName: group,
            permission: permission, expiresAt: expiresAt), using: .allow)
    }
}
