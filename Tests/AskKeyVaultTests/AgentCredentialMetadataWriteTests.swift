import CryptoKit
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentCredentialMetadataWriteTests: AgentTextWriteTestSupport {
    private let component = BrokerCredentialComponentInput(name: "token", value: .text("synthetic-token"), delivery: .none)

    private func approveAndCommit(_ request: AgentTextWriteRequest, harness: Harness,
                                  ticket: AgentTextWriteSubmission? = nil) throws -> AgentTextWriteResult {
        let ticket = try ticket ?? submitted(harness.vault.requestAgentTextWrite(request))
        XCTAssertEqual(ticket.state, .pending)
        _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        return try harness.vault.commitAgentTextWrite(request, requestID: ticket.requestID, capability: ticket.capability)
    }

    func testCreateResolvesExistingGroupSpellingWithNFCAndCaseFolding() throws {
        let harness = try makeHarness { _ in true }
        try harness.vault.createCredentialGroup("Café Services", using: .allow)
        let request = AgentTextWriteRequest(operationID: "existing-group", action: .createBundle(
            name: "Service", components: [component], usageInstructions: "Use only for staging", group: "  CAFE\u{301} SERVICES  "))
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        let summary = try harness.vault.frozenAgentWriteSummary(operationID: request.operationID,
            requestID: ticket.requestID, capability: ticket.capability)
        XCTAssertNil(summary.beforeUsageInstructions)
        XCTAssertEqual(summary.afterUsageInstructions, "Use only for staging")
        XCTAssertEqual(summary.afterGroup, "Café Services")
        XCTAssertFalse(summary.createsGroup)
        let result = try approveAndCommit(request, harness: harness, ticket: ticket)
        let stored = try harness.vault.revealTextCredential(id: result.credentialID, using: .allow)
        XCTAssertEqual(stored.usageInstructions, summary.afterUsageInstructions)
        XCTAssertEqual(stored.groupName, summary.afterGroup)
        XCTAssertEqual(stored.permission, .ask)
        XCTAssertEqual(try harness.vault.listCredentialGroups(), ["Café Services"])
    }

    func testNewGroupAppearsOnlyOnCommitAndCreationDefaultsRemainEmpty() throws {
        let harness = try makeHarness { _ in true }
        let request = AgentTextWriteRequest(operationID: "new-group", action: .createBundle(
            name: "Service", components: [component], usageInstructions: "Staging only", group: "  Staging  "))
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        let summary = try harness.vault.frozenAgentWriteSummary(operationID: request.operationID,
            requestID: ticket.requestID, capability: ticket.capability)
        XCTAssertTrue(summary.createsGroup)
        XCTAssertEqual(summary.afterGroup, "Staging")
        XCTAssertTrue(try harness.vault.listCredentialGroups().isEmpty)
        XCTAssertTrue(try harness.vault.brokerCredentialCatalog().isEmpty)
        _ = try approveAndCommit(request, harness: harness, ticket: ticket)
        XCTAssertEqual(try harness.vault.listCredentialGroups(), ["Staging"])
        XCTAssertEqual(try harness.vault.brokerCredentialCatalog().first?.group, "Staging")
        let defaults = AgentTextWriteRequest(operationID: "defaults", action: .createBundle(name: "Default", components: [component]))
        let result = try approveAndCommit(defaults, harness: harness)
        let stored = try harness.vault.revealTextCredential(id: result.credentialID, using: .allow)
        XCTAssertEqual(stored.usageInstructions, "")
        XCTAssertNil(stored.groupName)
    }

    func testExistingEquivalentGroupsReuseTheSameSpellingAtFreezeAndCommit() throws {
        let harness = try makeHarness { _ in true }
        try harness.vault.createCredentialGroup("Staging", using: .allow)
        try harness.vault.createCredentialGroup("STAGING", using: .allow)
        let request = AgentTextWriteRequest(operationID: "equivalent-groups", action: .createBundle(
            name: "Service", components: [component], group: "staging"))
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        let summary = try harness.vault.frozenAgentWriteSummary(operationID: request.operationID,
            requestID: ticket.requestID, capability: ticket.capability)
        XCTAssertEqual(summary.afterGroup, "STAGING")
        XCTAssertFalse(summary.createsGroup)
        let result = try approveAndCommit(request, harness: harness, ticket: ticket)
        XCTAssertEqual(try harness.vault.revealTextCredential(id: result.credentialID, using: .allow).groupName, summary.afterGroup)
        XCTAssertEqual(try harness.vault.listCredentialGroups(), ["STAGING", "Staging"])
    }

    func testMetadataOnlyPreservesTextAndFileStorageAndPrivateMetadata() throws {
        let harness = try makeHarness { _ in true }
        let text = try harness.vault.createTextCredential(.init(name: "Text", value: "synthetic-original",
            usageInstructions: "Original guidance", privateNotes: "synthetic-private", groupName: "Original",
            environmentVariable: "TOKEN", permission: .allowed), using: .allow)
        let file = try harness.vault.createFileCredential(.init(name: "File",
            snapshot: try .init(originalFilename: "key.pem", bytes: Data("synthetic-file".utf8)),
            usageInstructions: "Original guidance", privateNotes: "synthetic-private", groupName: "Original",
            environmentVariable: "KEY_FILE", permission: .allowed), using: .allow)
        for credential in [text, file] {
            let before = try XCTUnwrap(harness.store.fetchCredential(id: credential.id))
            let request = AgentTextWriteRequest(operationID: "metadata-" + credential.id, action: .modifyBundle(
                name: credential.name, usageInstructions: "Updated guidance", group: .named("New Group")))
            let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
            let summary = try harness.vault.frozenAgentWriteSummary(operationID: request.operationID,
                requestID: ticket.requestID, capability: ticket.capability)
            XCTAssertEqual(summary.beforeUsageInstructions, "Original guidance")
            XCTAssertEqual(summary.afterUsageInstructions, "Updated guidance")
            XCTAssertEqual(summary.beforeGroup, "Original")
            XCTAssertEqual(summary.afterGroup, "New Group")
            XCTAssertEqual(summary.before, summary.after)
            _ = try approveAndCommit(request, harness: harness, ticket: ticket)
            let after = try XCTUnwrap(harness.store.fetchCredential(id: credential.id))
            XCTAssertEqual(after.payloadKind, before.payloadKind)
            XCTAssertEqual(after.encryptedPayload, before.encryptedPayload)
            XCTAssertEqual(after.encryptedPrivateNotes, before.encryptedPrivateNotes)
            XCTAssertEqual(after.encryptedEnvironmentVariable, before.encryptedEnvironmentVariable)
            XCTAssertEqual(after.encryptedOriginalFilename, before.encryptedOriginalFilename)
            XCTAssertEqual(after.byteSize, before.byteSize)
            XCTAssertEqual(after.contentDigest, before.contentDigest)
            XCTAssertEqual(after.permission, before.permission)
            XCTAssertEqual(after.expiresAt, before.expiresAt)
        }
    }

    func testValuesOnlyPreserveMetadataAndCombinedWritesChangeBoth() throws {
        let harness = try makeHarness { _ in true }
        let created = try harness.vault.createBundleCredential(.init(name: "Service", components: [
            .init(name: "token", value: .text("synthetic-original"), delivery: .none)],
            usageInstructions: "Original", groupName: "Original", permission: .allowed), using: .allow)
        let valueOnly = AgentTextWriteRequest(operationID: "values", action: .modifyBundle(name: "Service", changes: [.upsert(component)]))
        _ = try approveAndCommit(valueOnly, harness: harness)
        var stored = try harness.vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(stored.usageInstructions, "Original")
        XCTAssertEqual(stored.groupName, "Original")
        XCTAssertEqual(stored.components.first?.value, .text("synthetic-token"))
        let combined = AgentTextWriteRequest(operationID: "combined", action: .modifyBundle(name: "Service", changes: [
            .upsert(.init(name: "token", value: .text("synthetic-combined"), delivery: .none))],
            usageInstructions: "Combined", group: .named("Combined")))
        _ = try approveAndCommit(combined, harness: harness)
        stored = try harness.vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(stored.components.first?.value, .text("synthetic-combined"))
        XCTAssertEqual(stored.usageInstructions, "Combined")
        XCTAssertEqual(stored.groupName, "Combined")
        XCTAssertEqual(stored.permission, .allowed)
    }

    func testClearInstructionsAndUngroupWithoutDeletingGroup() throws {
        let harness = try makeHarness { _ in true }
        try harness.vault.createCredentialGroup("Existing", using: .allow)
        let created = try harness.vault.createTextCredential(.init(name: "Service", value: "synthetic",
            usageInstructions: "Original", groupName: "Existing"), using: .allow)
        let request = AgentTextWriteRequest(operationID: "clear", action: .modifyBundle(
            name: "Service", usageInstructions: "", group: .ungrouped))
        _ = try approveAndCommit(request, harness: harness)
        let stored = try harness.vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(stored.usageInstructions, "")
        XCTAssertNil(stored.groupName)
        XCTAssertEqual(try harness.vault.listCredentialGroups(), ["Existing"])
    }

    func testUTF8InstructionBoundaryAndInvalidGroupsRejectBeforePersistence() throws {
        let harness = try makeHarness { _ in true }
        let boundary = String(repeating: "é", count: BrokerLimits.maximumFieldBytes / 2)
        let valid = AgentTextWriteRequest(operationID: "boundary", action: .createBundle(
            name: "Service", components: [component], usageInstructions: boundary))
        _ = try approveAndCommit(valid, harness: harness)
        for action: AgentTextWriteAction in [
            .createBundle(name: "Too Long", components: [component], usageInstructions: boundary + "x"),
            .modifyBundle(name: "Service", usageInstructions: boundary + "x"),
            .modifyBundle(name: "Service"),
            .modifyBundle(name: "Service", group: .named("  ")),
            .modifyBundle(name: "Service", group: .named("bad\nname")),
            .createBundle(name: "Bad Group", components: [component], group: String(repeating: "x", count: 256))
        ] {
            XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(.init(operationID: UUID().uuidString, action: action)))
        }
        XCTAssertEqual(try harness.vault.brokerCredentialCatalog().map(\.usageInstructions), [boundary])
        XCTAssertTrue(try harness.vault.listCredentialGroups().isEmpty)
    }

    func testChangedMetadataCannotReusePendingApprovedOrCommittedRequest() throws {
        let harness = try makeHarness { _ in true }
        let original = AgentTextWriteRequest(operationID: "bound", action: .createBundle(
            name: "Service", components: [component], usageInstructions: "Original", group: "Original"))
        let changed = [
            AgentTextWriteRequest(operationID: original.operationID, action: .createBundle(
                name: "Service", components: [component], usageInstructions: "Changed", group: "Original")),
            AgentTextWriteRequest(operationID: original.operationID, action: .createBundle(
                name: "Service", components: [component], usageInstructions: "Original", group: "Changed"))
        ]
        let ticket = try submitted(harness.vault.requestAgentTextWrite(original))
        for request in changed {
            XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(request)) {
                XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch)
            }
        }
        _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        for request in changed {
            XCTAssertThrowsError(try harness.vault.commitAgentTextWrite(request, requestID: ticket.requestID, capability: ticket.capability)) {
                XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch)
            }
        }
        let result = try harness.vault.commitAgentTextWrite(original, requestID: ticket.requestID, capability: ticket.capability)
        XCTAssertEqual(try harness.vault.commitAgentTextWrite(original, requestID: ticket.requestID, capability: ticket.capability), result)
        for request in changed {
            XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(request)) {
                XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch)
            }
        }
    }

    func testHiddenMetadataTargetIsGenericAndCatalogExposesGroupsOnlyForVisibleItems() throws {
        let harness = try makeHarness { _ in true }
        _ = try harness.vault.createTextCredential(.init(name: "Hidden", value: "synthetic-hidden",
            usageInstructions: "Hidden guidance", groupName: "Hidden Group", permission: .hidden), using: .allow)
        _ = try harness.vault.createTextCredential(.init(name: "Visible", value: "synthetic-visible", groupName: "Visible Group"), using: .allow)
        _ = try harness.vault.createTextCredential(.init(name: "Ungrouped", value: "synthetic-ungrouped"), using: .allow)
        let catalog = try harness.vault.brokerCredentialCatalog()
        XCTAssertEqual(catalog.map(\.name), ["Ungrouped", "Visible"])
        XCTAssertNil(catalog[0].group)
        XCTAssertEqual(catalog[1].group, "Visible Group")
        let wire = try encoded(catalog)
        XCTAssertTrue(wire.contains("\"group\":null"))
        XCTAssertFalse(wire.contains("Hidden"))
        for name in ["Hidden", "Missing"] {
            XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(.init(operationID: UUID().uuidString,
                action: .modifyBundle(name: name, usageInstructions: "New", group: .named("New"))))) {
                guard case VaultError.credentialUnavailable = $0 else { return XCTFail("Expected generic unavailable error") }
            }
        }
        let guesses = try harness.vault.listCredentialAccessRecords().filter { $0.result == .hiddenNameRejected }
        XCTAssertEqual(guesses.count, 2)
        XCTAssertTrue(guesses.allSatisfy { $0.credentialID == nil })
    }

    func testAllowAndTimedReadAllowanceStillRequireWriteAuthentication() throws {
        let authentications = AuthenticationPurposes()
        let harness = try makeHarness { purpose in authentications.append(purpose); return purpose == .readApproval }
        let created = try harness.vault.createTextCredential(.init(name: "Service", value: "synthetic", permission: .allowed), using: .allow)
        let read = BrokerApprovalOperationRequest(operationID: "read", credentialID: created.id, targetID: created.id,
            operation: .read, payloadDigest: String(repeating: "a", count: 64))
        let readTicket = try harness.vault.approvalRequests.submit(read, trustedCredentialDeadline: .none)
        _ = try harness.vault.approvalRequests.decide(requestID: readTicket.requestID, capability: readTicket.capability,
            decision: .timedAllow(duration: 60))
        let request = AgentTextWriteRequest(operationID: "write", action: .modifyBundle(name: "Service", usageInstructions: "New"))
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        XCTAssertEqual(ticket.state, .pending)
        XCTAssertThrowsError(try harness.vault.approvalRequests.decide(requestID: ticket.requestID,
            capability: ticket.capability, decision: .timedAllow(duration: 60))) {
            XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertThrowsError(try harness.vault.approvalRequests.decide(requestID: ticket.requestID,
            capability: ticket.capability, decision: .once)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .authenticationFailed)
        }
        XCTAssertEqual(authentications.values, [.readApproval, .writeApproval])
        XCTAssertThrowsError(try harness.vault.commitAgentTextWrite(request, requestID: ticket.requestID, capability: ticket.capability))
        XCTAssertEqual(try harness.vault.brokerCredentialCatalog().first?.usageInstructions, "")
    }

    func testGroupCreationAndReceiptRollBackWithCredentialThenRetryCommits() throws {
        let harness = try makeHarness { _ in true }
        let request = AgentTextWriteRequest(operationID: "atomic", action: .createBundle(name: "Service",
            components: [component], usageInstructions: "Guidance", group: "New Group"))
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        try harness.store.db.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_metadata_create BEFORE INSERT ON credentials BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        }
        XCTAssertThrowsError(try harness.vault.commitAgentTextWrite(request, requestID: ticket.requestID, capability: ticket.capability))
        XCTAssertTrue(try harness.vault.listCredentialGroups().isEmpty)
        XCTAssertTrue(try harness.vault.brokerCredentialCatalog().isEmpty)
        XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: request.operationID))
        XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .approved)
        try harness.store.db.write { try $0.execute(sql: "DROP TRIGGER fail_metadata_create") }
        _ = try harness.vault.commitAgentTextWrite(request, requestID: ticket.requestID, capability: ticket.capability)
        XCTAssertEqual(try harness.vault.listCredentialGroups(), ["New Group"])
        XCTAssertNotNil(try harness.store.fetchAgentWriteOperation(operationID: request.operationID))
    }

    func testInterleavedFrozenWritesMergeGroupsAndRejectChangedSpelling() throws {
        let harness = try makeHarness { _ in true }
        let requests = ["First", "Second"].map { name in AgentTextWriteRequest(operationID: name,
            action: .createBundle(name: name, components: [component], group: name)) }
        let tickets = try requests.map { try submitted(harness.vault.requestAgentTextWrite($0)) }
        for (request, ticket) in zip(requests, tickets) { _ = try approveAndCommit(request, harness: harness, ticket: ticket) }
        XCTAssertEqual(try harness.vault.listCredentialGroups(), ["First", "Second"])
        let conflicting = AgentTextWriteRequest(operationID: "conflict", action: .createBundle(
            name: "Conflict", components: [component], group: "Third"))
        let ticket = try submitted(harness.vault.requestAgentTextWrite(conflicting))
        try harness.vault.createCredentialGroup("THIRD", using: .allow)
        _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        XCTAssertThrowsError(try harness.vault.commitAgentTextWrite(conflicting, requestID: ticket.requestID, capability: ticket.capability)) {
            guard case VaultError.credentialChanged = $0 else { return XCTFail("Must not change approved group spelling") }
        }
        XCTAssertFalse(try harness.vault.brokerCredentialCatalog().contains { $0.name == "Conflict" })
    }
}
