import CryptoKit
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class ComponentMetadataTests: AgentTextWriteTestSupport {
    func testCatalogProjectionIsByteIdenticalWithoutDecryptingAnyPayload() throws {
        let harness = try makeHarness { _ in true }
        try createMaterials(in: harness)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let records = try harness.store.fetchAllCredentials()
        let expected = try records.map { record in
            BrokerCatalogItem(credentialID: record.id,
                name: try VaultCrypto.decrypt(record.encryptedDisplayName, using: harness.key),
                payloadKind: record.payloadKind == "file" ? .file : .text,
                usageInstructions: "", environmentVariable: try record.encryptedEnvironmentVariable.map {
                    try VaultCrypto.decrypt($0, using: harness.key)
                }, expired: false, components: try harness.vault.credentialComponents(from: record, key: harness.key).map {
                    BrokerCatalogComponent(name: $0.name, payloadKind: $0.value.payloadKind == .file ? .file : .text,
                                           delivery: $0.delivery)
                }, group: nil)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let before = try encoder.encode(expected)
        for var record in records {
            // Authenticated ciphertext tripwire: any attempt to decrypt values,
            // private notes or file names makes this successful catalog call fail.
            record.encryptedPayload = Data("synthetic-poison-payload".utf8)
            record.encryptedPrivateNotes = Data("synthetic-poison-notes".utf8)
            if record.encryptedOriginalFilename != nil {
                record.encryptedOriginalFilename = Data("synthetic-poison-filename".utf8)
            }
            try harness.store.updateCredential(record)
        }
        XCTAssertEqual(try encoder.encode(harness.vault.brokerCredentialCatalog()), before)
        XCTAssertEqual(try encoder.encode(harness.vault.brokerCredentialCatalog(cancellation: .init())), before)
    }

    func testUnavailableMetadataUsesExistingIntegrityFailureAndNeverBlocksDeny() throws {
        let unsupported = Data(#"{"version":2,"components":[]}"#.utf8)
        for variant in 0..<4 {
            let harness = try makeHarness { _ in true }
            let created = try harness.vault.createBundleCredential(.init(name: "Bundle", components: components), using: .allow)
            var record = try XCTUnwrap(harness.store.fetchCredential(id: created.id))
            switch variant {
            case 0: record.encryptedComponentMetadata = nil
            case 1: record.encryptedComponentMetadata = Data("synthetic-invalid-ciphertext".utf8)
            case 2:
                record.encryptedComponentMetadata = try VaultCrypto.encrypt(unsupported, using: harness.key)
            default:
                record.encryptedComponentMetadata = try VaultCrypto.encrypt("synthetic-invalid-json", using: harness.key)
            }
            try harness.store.updateCredential(record)
            XCTAssertThrowsError(try harness.vault.brokerCredentialCatalog()) {
                XCTAssertEqual($0 as? CredentialRecordAuthenticationError, .invalidAuthentication)
            }
            let request = runRequest()
            guard case .approvalRequired(let tickets) = try harness.vault.brokerTextCredentials(for: request, cancellation: .init()) else {
                return XCTFail("Unavailable names must leave Deny available")
            }
            let ticket = try XCTUnwrap(tickets.first)
            XCTAssertNil(harness.vault.approvalRequests.pendingRequests().first?.request.display?.environmentVariables)
            _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .deny)
            XCTAssertThrowsError(try harness.vault.brokerTextCredentials(for: request, cancellation: .init()))
        }
    }

    func testDeliveryChecksEveryComponentBeforeMaterializingAnyFile() throws {
        for change in ["name", "kind", "mapping", "order", "missing", "corrupt", "version"] {
            let harness = try makeHarness { _ in true }
            let materializations = ConcurrentResults<Int32>()
            let manager = try FileDeliveryManager(
                rootURL: harness.databaseURL.deletingLastPathComponent().appendingPathComponent("deliveries"),
                synchronizeFile: { descriptor in materializations.append(.success(descriptor)); return 0 })
            defer { manager.cleanupAll() }
            let vault = Vault(store: harness.store, key: harness.key,
                              approvalRequests: harness.vault.approvalRequests, fileDeliveryManager: manager)
            let created = try harness.vault.createBundleCredential(.init(name: "Bundle", components: components), using: .allow)
            let request = runRequest()
            guard case .approvalRequired(let tickets) = try vault.brokerTextCredentials(for: request, cancellation: .init()) else {
                return XCTFail("Expected approval")
            }
            let ticket = try XCTUnwrap(tickets.first)
            _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
            var record = try XCTUnwrap(harness.store.fetchCredential(id: created.id))
            var changed = components
            switch change {
            case "name": changed[1].name = "Other"
            case "kind": changed[1].value = .file(filename: "synthetic", bytes: Data("synthetic".utf8))
            case "mapping": changed[1].delivery = .temporaryFile("OTHER_FILE")
            case "order": changed.reverse()
            default: break
            }
            record.encryptedComponentMetadata = change == "missing" ? nil
                : try CredentialComponentMetadata(components: changed).encrypted(using: harness.key)
            if change == "corrupt" { record.encryptedComponentMetadata = Data("synthetic-invalid-ciphertext".utf8) }
            if change == "version" {
                record.encryptedComponentMetadata = try VaultCrypto.encrypt(#"{"version":2,"components":[]}"#, using: harness.key)
            }
            try harness.store.updateCredential(record)
            XCTAssertThrowsError(try vault.brokerTextCredentials(for: request, cancellation: .init())) {
                XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch, change)
            }
            XCTAssertTrue(materializations.values.isEmpty, "No file may be materialized before all component metadata matches")
        }
    }

    func testReadApprovalRejectsRollbackToOlderAuthenticatedMappingForEveryPayloadKind() throws {
        for kind in [CredentialPayloadKind.text, .file, .bundle] {
            let harness = try makeHarness { _ in true }
            try createMaterials(in: harness)
            var old = try XCTUnwrap(harness.store.fetchAllCredentials().first { $0.payloadKind == kind.rawValue })
            old.permission = CredentialPermission.ask.rawValue
            try harness.store.updateCredential(old)
            old = try XCTUnwrap(harness.store.fetchCredential(id: old.id))
            switch kind {
            case .text:
                _ = try harness.vault.updateTextCredential(id: old.id,
                    .init(name: "Text", value: "synthetic-new", environmentVariable: "NEW_TOKEN", permission: .ask), using: .allow)
            case .file:
                _ = try harness.vault.updateFileCredential(id: old.id,
                    .init(name: "File", environmentVariable: "NEW_FILE", permission: .ask), using: .allow)
            case .bundle:
                _ = try harness.vault.updateBundleCredential(id: old.id,
                    .init(name: "Bundle", components: [.init(name: "New", value: .text("synthetic-new"))], permission: .ask), using: .allow)
            }
            let name = try VaultCrypto.decrypt(old.encryptedDisplayName, using: harness.key)
            let request = BrokerTextRunRequest(operationID: UUID().uuidString, command: ["/usr/bin/true"], credentialNames: [name])
            guard case .approvalRequired(let tickets) = try harness.vault.brokerTextCredentials(for: request, cancellation: .init()) else {
                return XCTFail("Expected read approval")
            }
            let ticket = try XCTUnwrap(tickets.first)
            _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
            // Replay the whole signed historical row without re-sealing it.
            try harness.store.db.write { try old.update($0) }
            try CredentialRecordAuthentication.verify(try XCTUnwrap(harness.store.fetchCredential(id: old.id)), using: harness.key)
            XCTAssertThrowsError(try harness.vault.brokerTextCredentials(for: request, cancellation: .init())) {
                XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch, kind.rawValue)
            }
        }
    }

    func testInvalidControlTerminatedDeliveryNamesNeverReachBundleDisplay() throws {
        for suffix in ["\n", "\r\n"] {
            let harness = try makeHarness { _ in true }
            let created = try harness.vault.createBundleCredential(.init(name: "Bundle", components: components), using: .allow)
            var record = try XCTUnwrap(harness.store.fetchCredential(id: created.id))
            let invalid = [CredentialComponentInput(name: "Token", value: .text("synthetic"), delivery: .environmentVariable("TOKEN" + suffix))]
            record.encryptedComponentMetadata = try CredentialComponentMetadata(components: invalid).encrypted(using: harness.key)
            try harness.store.updateCredential(record)
            guard case .approvalRequired(let tickets) = try harness.vault.brokerTextCredentials(for: runRequest(), cancellation: .init()) else {
                return XCTFail("Deny must stay available")
            }
            let display = try XCTUnwrap(harness.vault.approvalRequests.pendingRequests().first?.request.display)
            XCTAssertNil(display.components)
            XCTAssertNil(display.environmentVariables)
            XCTAssertFalse(String(describing: display).contains("TOKEN" + suffix))
            let ticket = try XCTUnwrap(tickets.first)
            XCTAssertNoThrow(try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .deny))
        }
    }

    func testManagementImportAndRecycleWritePathsPreserveMatchingMetadata() throws {
        let harness = try makeHarness { _ in true }
        try createMaterials(in: harness)
        let initial = try harness.store.fetchAllCredentials()
        let text = try XCTUnwrap(initial.first { $0.payloadKind == "text" })
        let file = try XCTUnwrap(initial.first { $0.payloadKind == "file" })
        let bundle = try XCTUnwrap(initial.first { $0.payloadKind == "bundle" })
        _ = try harness.vault.updateTextCredential(id: text.id,
            .init(name: "Text", value: "synthetic-new", environmentVariable: "NEW_TOKEN"), using: .allow)
        _ = try harness.vault.updateFileCredential(id: file.id,
            .init(name: "File", environmentVariable: "NEW_FILE"), using: .allow)
        let replacement = [CredentialComponentInput(name: "Replacement", value: .text("synthetic-replacement"), delivery: .none)]
        _ = try harness.vault.updateBundleCredential(id: bundle.id,
            .init(name: "Bundle", components: replacement), using: .allow)
        _ = try harness.vault.replaceImportedBundleCredential(id: bundle.id, components: components, using: .allow)
        try harness.store.recycleCredential(id: bundle.id, deletedAt: "2026-01-01T00:00:00Z")
        let recycled = try XCTUnwrap(harness.store.fetchRecycledCredentials().first)
        try assertMatches(recycled, harness: harness)
        try harness.store.restoreCredential(id: bundle.id)
        for record in try harness.store.fetchAllCredentials() { try assertMatches(record, harness: harness) }
    }

    func testAgentBundleCreateModifyAndValueOnlyTextCommitsStoreMetadata() throws {
        let harness = try makeHarness { _ in true }
        let create = AgentTextWriteRequest(operationID: "create-bundle", action: .createBundle(name: "Bundle", components: [
            .init(name: "Token", value: .text("synthetic-token"), delivery: .environmentVariable("TOKEN"))
        ]))
        let result = try commit(create, harness: harness)
        try assertMatches(try XCTUnwrap(harness.store.fetchCredential(id: result.credentialID)), harness: harness)
        _ = try commit(.init(operationID: "modify-bundle", action: .modifyBundle(name: "Bundle", changes: [
            .upsert(.init(name: "Token", value: .text("synthetic-new"), delivery: .temporaryFile("TOKEN_FILE")))
        ])), harness: harness)
        try assertMatches(try XCTUnwrap(harness.store.fetchCredential(id: result.credentialID)), harness: harness)
        let text = try commit(.init(operationID: "create-text", action: .create(name: "Text", value: "synthetic")), harness: harness)
        _ = try commit(.init(operationID: "modify-text", action: .modify(name: "Text", value: "synthetic-new")), harness: harness)
        try assertMatches(try XCTUnwrap(harness.store.fetchCredential(id: text.credentialID)), harness: harness)
    }

    private func commit(_ request: AgentTextWriteRequest, harness: Harness) throws -> AgentTextWriteResult {
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        return try harness.vault.commitAgentTextWrite(request, requestID: ticket.requestID, capability: ticket.capability)
    }

    private var components: [CredentialComponentInput] {
        [.init(name: "Certificate", value: .file(filename: "synthetic.pem", bytes: Data("synthetic-file".utf8)),
               delivery: .temporaryFile("CERT_FILE")),
         .init(name: "Token", value: .text("synthetic-token"), delivery: .temporaryFile("TOKEN_FILE")),
         .init(name: "Local", value: .text("synthetic-local"), delivery: .none)]
    }

    private func runRequest() -> BrokerTextRunRequest {
        .init(operationID: UUID().uuidString, command: ["/synthetic/deploy"], credentialNames: ["Bundle"])
    }

    private func createMaterials(in harness: Harness) throws {
        _ = try harness.vault.createTextCredential(.init(name: "Text", value: "synthetic-text", environmentVariable: "TOKEN"), using: .allow)
        _ = try harness.vault.createFileCredential(.init(name: "File",
            snapshot: try .init(originalFilename: "synthetic.pem", bytes: Data("synthetic-file".utf8)),
            environmentVariable: "KEY_FILE"), using: .allow)
        _ = try harness.vault.createBundleCredential(.init(name: "Bundle", components: components), using: .allow)
    }

    private func assertMatches(_ record: CredentialRecord, harness: Harness, file: StaticString = #filePath, line: UInt = #line) throws {
        try CredentialRecordAuthentication.verify(record, using: harness.key)
        XCTAssertEqual(try CredentialComponentMetadata.read(from: record, using: harness.key),
                       try CredentialComponentMetadata(components: harness.vault.credentialComponents(from: record, key: harness.key)),
                       file: file, line: line)
        let plaintext = try VaultCrypto.decryptData(XCTUnwrap(record.encryptedComponentMetadata), using: harness.key)
        for secret in ["synthetic-token", "synthetic-file", "synthetic.pem", "synthetic-new"] {
            XCTAssertFalse(String(decoding: plaintext, as: UTF8.self).contains(secret), file: file, line: line)
        }
    }
}
