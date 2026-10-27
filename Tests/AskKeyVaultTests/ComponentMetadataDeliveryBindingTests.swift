import CryptoKit
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class ComponentMetadataDeliveryBindingTests: AgentTextWriteTestSupport {
    private let components: [CredentialComponentInput] = [
        .init(name: "File", value: .file(filename: "synthetic.pem", bytes: Data("synthetic-file".utf8)), delivery: .temporaryFile("KEY_FILE")),
        .init(name: "Token", value: .text("synthetic-token"), delivery: .environmentVariable("TOKEN")),
    ]

    func testPayloadOnlyProjectionMismatchReachesFinalComparisonBeforeAnyFileMaterializes() throws {
        for change in ["name", "kind", "mapping", "order"] {
            let harness = try makeHarness { _ in true }
            let (vault, materializations) = try deliveryVault(harness)
            let created = try harness.vault.createBundleCredential(.init(name: "Bundle", components: components), using: .allow)
            let request = makeRunRequest()
            let ticket = try pending(request, vault: vault)
            let approval = try XCTUnwrap(vault.approvalRequests.pendingRequests().first?.request)
            _ = try vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
            var changed = components
            switch change {
            case "name": changed[1].name = "Other"
            case "kind": changed[1].value = .file(filename: "synthetic-new.pem", bytes: Data("synthetic-new".utf8)); changed[1].delivery = .temporaryFile("TOKEN")
            case "mapping": changed[1].delivery = .environmentVariable("OTHER_TOKEN")
            default: changed.reverse()
            }
            var record = try XCTUnwrap(harness.store.fetchCredential(id: created.id))
            let metadata = record.encryptedComponentMetadata
            record.encryptedPayload = try VaultCrypto.encrypt(JSONEncoder().encode(changed), using: harness.key)
            try harness.store.updateCredential(record)
            XCTAssertEqual(try harness.store.fetchCredential(id: created.id)?.encryptedComponentMetadata, metadata)
            XCTAssertEqual(try vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability, operationRequest: approval), .approved)
            XCTAssertThrowsError(try vault.brokerTextCredentials(for: request, cancellation: .init())) {
                XCTAssertEqual($0 as? CredentialRecordAuthenticationError, .invalidAuthentication, change)
            }
            XCTAssertEqual(try vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .consumed,
                "The unchanged approval must reach consumption, beyond the resubmission fence")
            XCTAssertTrue(materializations.values.isEmpty)
        }
    }

    func testApprovedUnavailableMetadataStillRefusesDeliveryAndBecomingAvailableInvalidatesIt() throws {
        for becomesAvailable in [false, true] {
            let harness = try makeHarness { _ in true }
            let (vault, materializations) = try deliveryVault(harness)
            let created = try harness.vault.createBundleCredential(.init(name: "Bundle", components: components), using: .allow)
            var record = try XCTUnwrap(harness.store.fetchCredential(id: created.id))
            let available = record.encryptedComponentMetadata
            record.encryptedComponentMetadata = nil
            try harness.store.updateCredential(record)
            let request = makeRunRequest()
            let ticket = try pending(request, vault: vault)
            _ = try vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
            if becomesAvailable {
                record.encryptedComponentMetadata = available
                try harness.store.updateCredential(record)
            }
            XCTAssertThrowsError(try vault.brokerTextCredentials(for: request, cancellation: .init())) {
                if becomesAvailable { XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch) }
                else { XCTAssertEqual($0 as? CredentialRecordAuthenticationError, .invalidAuthentication) }
            }
            XCTAssertTrue(materializations.values.isEmpty)
        }
    }

    func testTimedAllowanceRequiresTheGrantedProjectionForNewReads() throws {
        let harness = try makeHarness { _ in true }
        try harness.vault.updateTimedAllowance(enabled: true, minutes: 30)
        let created = try harness.vault.createBundleCredential(.init(name: "Bundle", components: components), using: .allow)
        let old = try XCTUnwrap(harness.store.fetchCredential(id: created.id))
        var changed = components
        changed[1].delivery = .environmentVariable("NEW_TOKEN")
        _ = try harness.vault.updateBundleCredential(id: created.id, .init(name: "Bundle", components: changed), using: .allow)
        let first = makeRunRequest()
        let ticket = try pending(first, vault: harness.vault)
        _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllow(duration: nil))
        try resolve(first, vault: harness.vault)
        try resolve(makeRunRequest(), vault: harness.vault)
        // Restore the whole authenticated historical row, bypassing management
        // mutation's deliberate allowance revocation.
        try harness.store.db.write { try old.update($0) }
        XCTAssertNotNil(harness.vault.approvalRequests.timedAllowanceDeadline(credentialID: old.id))
        _ = try pending(makeRunRequest(), vault: harness.vault)
        XCTAssertEqual(harness.vault.approvalRequests.pendingRequests().last?.request.display?.environmentVariables, ["TOKEN"])
    }

    private func makeRunRequest() -> BrokerTextRunRequest {
        .init(operationID: UUID().uuidString, command: ["/usr/bin/true"], credentialNames: ["Bundle"])
    }

    private func pending(_ request: BrokerTextRunRequest, vault: Vault) throws -> BrokerApprovalTicket {
        guard case .approvalRequired(let tickets) = try vault.brokerTextCredentials(for: request, cancellation: .init()) else {
            throw BrokerApprovalError.invalidDecision
        }
        return try XCTUnwrap(tickets.first)
    }

    private func resolve(_ request: BrokerTextRunRequest, vault: Vault) throws {
        guard case .resolved(_, _, let lease) = try vault.brokerTextCredentials(for: request, cancellation: .init()) else {
            return XCTFail("Expected a granted timed read")
        }
        lease?.finish(); lease?.cleanup()
    }

    private func deliveryVault(_ harness: Harness) throws -> (Vault, ConcurrentResults<Int32>) {
        let writes = ConcurrentResults<Int32>()
        let manager = try FileDeliveryManager(rootURL: harness.databaseURL.deletingLastPathComponent().appendingPathComponent("deliveries"),
            synchronizeFile: { descriptor in writes.append(.success(descriptor)); return 0 })
        addTeardownBlock { manager.cleanupAll() }
        return (Vault(store: harness.store, key: harness.key, approvalRequests: harness.vault.approvalRequests, fileDeliveryManager: manager), writes)
    }
}
