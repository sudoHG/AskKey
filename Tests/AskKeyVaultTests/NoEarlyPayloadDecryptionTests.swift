import CryptoKit
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class NoEarlyPayloadDecryptionTests: AgentTextWriteTestSupport {
    private func bundle(_ harness: Harness) throws -> ManagedTextCredential {
        try harness.vault.createBundleCredential(.init(name: "Synthetic Service", components: [
            .init(name: "TOKEN", value: .text("synthetic-token"), delivery: .environmentVariable("SERVICE_TOKEN")),
            .init(name: "USER", value: .text("synthetic-user"), delivery: .environmentVariable("SERVICE_USER"), masked: false),
            .init(name: "CERT", value: .file(filename: "synthetic.pem", bytes: Data("synthetic-file".utf8)),
                delivery: .temporaryFile("SERVICE_CERT"))
        ]), using: .allow)
    }

    private func corruptPayload(_ credential: ManagedTextCredential, harness: Harness) throws -> CredentialRecord {
        var record = try XCTUnwrap(harness.store.fetchCredential(id: credential.id))
        record.encryptedPayload = Data("synthetic-unreadable-payload".utf8)
        try harness.store.updateCredential(record)
        return try XCTUnwrap(harness.store.fetchCredential(id: credential.id))
    }

    private func approve(_ ticket: AgentTextWriteSubmission, harness: Harness) throws {
        _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
    }

    private func commit(_ request: AgentTextWriteRequest, ticket: AgentTextWriteSubmission, harness: Harness) throws {
        _ = try harness.vault.commitAgentTextWrite(request, requestID: ticket.requestID, capability: ticket.capability)
    }

    func testManagementListTrashAndEveryNoSecretsProjectionAcceptUnreadablePayloads() throws {
        let harness = try makeHarness { _ in true }
        let credentials = try [
            bundle(harness),
            harness.vault.createTextCredential(.init(name: "Text", value: "synthetic", environmentVariable: "TEXT"), using: .allow),
            harness.vault.createFileCredential(.init(name: "File",
                snapshot: .init(originalFilename: "synthetic.pem", bytes: Data("synthetic".utf8)),
                environmentVariable: "FILE_PATH"), using: .allow)
        ]
        for credential in credentials {
            let row = try corruptPayload(credential, harness: harness)
            let projection = try harness.vault.managedCredential(from: row, key: harness.key, includeSecrets: false)
            XCTAssertNil(projection.value)
            XCTAssertNil(projection.fileBytes)
            XCTAssertTrue(projection.components.allSatisfy { $0.value == nil })
            XCTAssertEqual(projection.environmentVariable, credential.environmentVariable)
            XCTAssertEqual(projection.components.map(\.name), credential.components.map(\.name))
            XCTAssertEqual(projection.components.map(\.kind), credential.components.map(\.kind))
            XCTAssertEqual(projection.components.map(\.delivery), credential.components.map(\.delivery))
            XCTAssertThrowsError(try harness.vault.managedCredential(from: row, key: harness.key, includeSecrets: true))
        }
        XCTAssertEqual(try harness.vault.listTextCredentials().count, 3)
        for credential in credentials {
            try harness.vault.deleteTextCredential(id: credential.id, using: .allow)
        }
        XCTAssertEqual(try harness.vault.listRecycledTextCredentials().count, 3)
    }

    func testSavingUnrevealedMetadataPreservesComponentsAndRealMasking() throws {
        let harness = try makeHarness { _ in true }
        let created = try bundle(harness)
        XCTAssertTrue(created.components.allSatisfy(\.masked), "Unrevealed masking is conservative")
        let before = try XCTUnwrap(harness.store.fetchCredential(id: created.id))
        try harness.vault.updateCredentialMetadata(id: created.id, name: created.name,
            usageInstructions: "Updated without reveal", groupName: "Staging", permission: .ask,
            expiresAt: nil, using: .allow)
        let after = try XCTUnwrap(harness.store.fetchCredential(id: created.id))
        XCTAssertEqual(after.encryptedPayload, before.encryptedPayload)
        XCTAssertEqual(after.encryptedComponentMetadata, before.encryptedComponentMetadata)
        let revealed = try harness.vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(revealed.components.map(\.masked), [true, false, true])
        XCTAssertEqual(revealed.components.map(\.value), try harness.vault.credentialComponents(from: before, key: harness.key).map { Optional($0.value) })
    }

    func testDeleteAndMetadataOnlyModifyNeverOpenStoredPayloads() throws {
        for kind in [CredentialPayloadKind.text, .file, .bundle] {
            let harness = try makeHarness { _ in true }
            let credential: ManagedTextCredential
            switch kind {
            case .text: credential = try harness.vault.createTextCredential(.init(name: "Synthetic Service", value: "synthetic"), using: .allow)
            case .file: credential = try harness.vault.createFileCredential(.init(name: "Synthetic Service",
                snapshot: .init(originalFilename: "synthetic.pem", bytes: Data("synthetic".utf8))), using: .allow)
            case .bundle: credential = try bundle(harness)
            }
            let original = try corruptPayload(credential, harness: harness)
            for action in [
                AgentTextWriteAction.modifyBundle(name: credential.name, usageInstructions: "Updated guidance"),
                .modifyBundle(name: credential.name, group: .named("Staging")),
                .delete(name: credential.name)
            ] {
                let request = AgentTextWriteRequest(operationID: UUID().uuidString, action: action)
                let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
                let summary = try harness.vault.frozenAgentWriteSummary(operationID: request.operationID,
                    requestID: ticket.requestID, capability: ticket.capability)
                XCTAssertNil(summary.beforeDigest)
                XCTAssertTrue(summary.before.allSatisfy { $0.byteCount == nil && $0.valueDigest == nil })
                XCTAssertThrowsError(try commit(request, ticket: ticket, harness: harness))
                try approve(ticket, harness: harness)
                try commit(request, ticket: ticket, harness: harness)
                let row = try XCTUnwrap(harness.store.fetchCredentialIncludingRecycled(nameIndex: original.nameIndex))
                XCTAssertEqual(row.encryptedPayload, original.encryptedPayload)
                XCTAssertEqual(row.encryptedComponentMetadata, original.encryptedComponentMetadata)
            }
        }
    }

    func testComponentModifyOpensPayloadOnlyAtApprovedCommitAndRollsBackUnreadableMaterial() throws {
        let purposes = AuthenticationPurposes()
        let harness = try makeHarness { purposes.append($0); return true }
        let created = try bundle(harness)
        let original = try corruptPayload(created, harness: harness)
        let request = AgentTextWriteRequest(operationID: "replace", action: .modifyBundle(name: created.name,
            changes: [.upsert(.init(name: "TOKEN", value: .text("synthetic-new"), delivery: .environmentVariable("SERVICE_TOKEN")))]))
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        XCTAssertTrue(purposes.values.isEmpty)
        XCTAssertThrowsError(try commit(request, ticket: ticket, harness: harness))
        try approve(ticket, harness: harness)
        XCTAssertEqual(purposes.values.count, 1)
        XCTAssertThrowsError(try commit(request, ticket: ticket, harness: harness)) {
            switch $0 {
            case VaultError.decryptionFailed, CryptoKitError.authenticationFailure: break
            default: XCTFail("Expected payload decryption only at commit: \($0)")
            }
        }
        XCTAssertEqual(try harness.store.fetchCredential(id: created.id)?.encryptedPayload, original.encryptedPayload)
        XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: request.operationID))
    }

    func testComponentCommitPreservesUntouchedValuesAndRevealOmitsThem() throws {
        let harness = try makeHarness { _ in true }
        let created = try bundle(harness)
        let request = AgentTextWriteRequest(operationID: "replace-and-remove", action: .modifyBundle(name: created.name, changes: [
            .upsert(.init(name: "TOKEN", value: .text("synthetic-new"), delivery: .environmentVariable("SERVICE_TOKEN"))),
            .remove("CERT")
        ]))
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        let reveal = try harness.vault.revealFrozenCredentialWrite(operationID: request.operationID,
            requestID: ticket.requestID, capability: ticket.capability, using: .allow)
        XCTAssertEqual(reveal.before.map(\.name), ["TOKEN", "CERT"])
        XCTAssertEqual(reveal.after.map(\.name), ["TOKEN"])
        XCTAssertFalse(String(describing: reveal).contains("synthetic-user"))
        try approve(ticket, harness: harness)
        try commit(request, ticket: ticket, harness: harness)
        let stored = try harness.vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(stored.components.map(\.name), ["TOKEN", "USER"])
        XCTAssertEqual(stored.components.map(\.value), [.text("synthetic-new"), .text("synthetic-user")])
        XCTAssertEqual(stored.components.map(\.masked), [true, false])
    }

    func testMetadataConflictsRejectBeforeApprovalWithoutOpeningPayload() throws {
        let harness = try makeHarness { _ in true }
        let created = try bundle(harness)
        _ = try corruptPayload(created, harness: harness)
        let file = Data("synthetic-file".utf8)
        let reference = BrokerComponentFileReference(uploadID: "synthetic-upload", capability: "synthetic-capability", digest: Vault.componentDigest(file))
        let conflicts: [[BrokerCredentialComponentChange]] = [
            [.upsert(.init(name: "TOKEN", value: .text("new"), delivery: .none)), .remove("token")],
            [.upsert(.init(name: "EXTRA", value: .text("new"), delivery: .environmentVariable("SERVICE_USER")))],
            [.upsert(.init(name: "FILE", value: .file(reference), delivery: .environmentVariable("BAD_FILE")))],
            [.remove("missing")], [.remove("TOKEN"), .remove("USER"), .remove("CERT")]
        ]
        for changes in conflicts {
            let request = AgentTextWriteRequest(operationID: UUID().uuidString, action: .modifyBundle(name: created.name, changes: changes))
            XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(request, fileResolver: { _ in
                .init(originalFilename: "synthetic.pem", bytes: file, digest: reference.digest)
            })) { error in
                switch error {
                case BrokerApprovalError.invalidRequest, VaultError.databaseError: break
                default: XCTFail("Expected metadata validation, not payload access: \(error)")
                }
            }
            XCTAssertNil(harness.vault.agentTextWrites.entry(operationID: request.operationID))
            XCTAssertTrue(harness.vault.approvalRequests.pendingRequests().isEmpty)
        }
    }

    func testMissingOrInvalidMetadataFailsClosedInListTrashAndWrites() throws {
        for ciphertext in [nil, Data("synthetic-invalid-metadata".utf8)] as [Data?] {
            let harness = try makeHarness { _ in true }
            let created = try bundle(harness)
            var row = try XCTUnwrap(harness.store.fetchCredential(id: created.id))
            row.encryptedComponentMetadata = ciphertext
            try harness.store.updateCredential(row)
            // Management retains the row for authenticated repair, with no
            // component claims or payload fallback. Agent access stays closed.
            row.encryptedPayload = Data("synthetic-unreadable-payload".utf8)
            try harness.store.updateCredential(row)
            let projection = try XCTUnwrap(harness.vault.listTextCredentials().first)
            XCTAssertFalse(projection.componentDetailsAvailable)
            XCTAssertTrue(projection.components.isEmpty)
            XCTAssertNil(projection.environmentVariable)
            XCTAssertNil(projection.value)
            for action in [AgentTextWriteAction.delete(name: created.name), .modifyBundle(name: created.name, usageInstructions: "New")] {
                XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(.init(operationID: UUID().uuidString, action: action))) {
                    XCTAssertEqual($0 as? CredentialRecordAuthenticationError, .invalidAuthentication)
                }
            }
            try harness.vault.deleteTextCredential(id: created.id, using: .allow)
            XCTAssertFalse(try XCTUnwrap(harness.vault.listRecycledTextCredentials().first).componentDetailsAvailable)
        }
    }

    func testMergedSizeRejectionWritesNothingAfterApproval() throws {
        let harness = try makeHarness { _ in true }
        let created = try harness.vault.createBundleCredential(.init(name: "Large", components: [
            .init(name: "FILE", value: .file(filename: "synthetic.bin",
                bytes: Data(repeating: 42, count: CredentialBundleValidator.maximumMaterialBytes)), delivery: .none)
        ]), using: .allow)
        let original = try XCTUnwrap(harness.store.fetchCredential(id: created.id))
        let request = AgentTextWriteRequest(operationID: "over-limit", action: .modifyBundle(name: created.name,
            changes: [.upsert(.init(name: "EXTRA", value: .text("x"), delivery: .none))], group: .named("Rollback Group")))
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        try approve(ticket, harness: harness)
        XCTAssertThrowsError(try commit(request, ticket: ticket, harness: harness)) {
            guard case VaultError.agentWriteMaterialTooLarge = $0 else { return XCTFail("Expected clear size failure: \($0)") }
            XCTAssertEqual($0.localizedDescription, "The updated credential exceeds the 5 MiB size limit. The credential was not saved.")
        }
        XCTAssertEqual(try harness.store.fetchCredential(id: created.id)?.agentWriteStateDigest(), try original.agentWriteStateDigest())
        XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: request.operationID))
        XCTAssertEqual(try harness.vault.listCredentialGroups(), [])
    }

    func testUnavailableMetadataNeverFallsBackToPayloadOrLegacyMappingForAnyKind() throws {
        let harness = try makeHarness { _ in true }
        let credentials = try [bundle(harness),
            harness.vault.createTextCredential(.init(name: "Text", value: "synthetic", environmentVariable: "TEXT"), using: .allow),
            harness.vault.createFileCredential(.init(name: "File", snapshot: .init(originalFilename: "synthetic.pem",
                bytes: Data("synthetic".utf8)), environmentVariable: "FILE_PATH"), using: .allow)]
        for credential in credentials {
            var row = try corruptPayload(credential, harness: harness)
            row.encryptedComponentMetadata = nil
            try harness.store.updateCredential(row)
        }
        let listed = try harness.vault.listTextCredentials()
        XCTAssertEqual(listed.count, 3)
        for credential in listed {
            XCTAssertFalse(credential.componentDetailsAvailable)
            XCTAssertTrue(credential.components.isEmpty)
            XCTAssertNil(credential.environmentVariable)
            XCTAssertNil(credential.value)
            XCTAssertNil(credential.fileBytes)
        }
    }
}
