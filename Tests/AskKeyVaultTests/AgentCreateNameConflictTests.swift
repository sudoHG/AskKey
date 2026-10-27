import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentCreateNameConflictTests: AgentTextWriteTestSupport {
    func testVisibleDuplicatesReturnSpecificErrorForBothAgentCreateActions() throws {
        for permission in [CredentialPermission.ask, .allowed] {
            for kind in [CredentialPayloadKind.text, .file, .bundle] {
                let harness = try makeHarness(authenticate: { _ in true })
                let existing = try createExisting(harness, kind: kind, permission: permission)
                let handler = handler(for: harness)
                XCTAssertEqual(try harness.vault.brokerCredentialCatalog().map(\.credentialID), [existing.id])

                for action in createActions(named: "  café token  ") {
                    XCTAssertEqual(response(to: action, handler: handler), .failure(.credentialNameConflict))
                }
                XCTAssertTrue(harness.vault.approvalRequests.pendingRequests().isEmpty)
                XCTAssertEqual(try harness.vault.listTextCredentials().map(\.id), [existing.id])
            }
        }
    }

    func testUnavailableNamesUseTheSameFrozenApprovalAsFreeNames() throws {
        for recycled in [false, true] {
            for kind in [CredentialPayloadKind.text, .file, .bundle] {
                for action in createActions(named: "  café token  ") {
                    let harness = try makeHarness(authenticate: { _ in true })
                    let free = AgentTextWriteRequest(operationID: UUID().uuidString, action: action)
                    let freeTicket = try request(free, in: harness)
                    let freeReplay = try request(free, in: harness)
                    let freeFrozen = try XCTUnwrap(harness.vault.agentTextWrites.entry(operationID: free.operationID))
                    _ = try harness.vault.approvalRequests.decide(requestID: freeTicket.requestID,
                        capability: freeTicket.capability, decision: .deny)
                    let existing = try createExisting(harness, kind: kind, permission: recycled ? .allowed : .hidden)
                    if recycled { try harness.vault.deleteTextCredential(id: existing.id, using: .allow) }
                    XCTAssertTrue(try harness.vault.brokerCredentialCatalog().isEmpty)

                    let unavailable = AgentTextWriteRequest(operationID: UUID().uuidString, action: action)
                    let ticket = try request(unavailable, in: harness)
                    let frozen = try XCTUnwrap(harness.vault.agentTextWrites.entry(operationID: unavailable.operationID))
                    XCTAssertEqual(ticket.state, freeTicket.state)
                    XCTAssertEqual(ticket.retryCount, freeTicket.retryCount)
                    XCTAssertEqual(frozen.summary, freeFrozen.summary)
                    XCTAssertNil(frozen.beforeRecord)
                    XCTAssertNil(frozen.credentialExpiresAt)
                    XCTAssertNotEqual(frozen.approvalRequest.credentialID, existing.id)
                    XCTAssertEqual(harness.vault.approvalRequests.pendingRequests().count, 1)
                    let replay = try request(unavailable, in: harness)
                    XCTAssertEqual(replay.requestID, ticket.requestID)
                    XCTAssertEqual(replay.capability, ticket.capability)
                    XCTAssertEqual(replay.state, ticket.state)
                    XCTAssertEqual(replay.retryCount, freeReplay.retryCount)
                }
            }
        }
    }

    func testUnavailableNamesReturnNormalDenialWithoutWriting() throws {
        for recycled in [false, true] {
            for action in createActions(named: "café token") {
                let harness = try makeHarness(authenticate: { _ in true })
                let existing = try createExisting(harness, kind: .text, permission: recycled ? .allowed : .hidden)
                if recycled { try harness.vault.deleteTextCredential(id: existing.id, using: .allow) }
                let original = try credentialSnapshot(harness)
                let write = AgentTextWriteRequest(operationID: UUID().uuidString, action: action)
                let ticket = try request(write, in: harness)
                _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID,
                    capability: ticket.capability, decision: .deny)
                XCTAssertEqual(try request(write, in: harness).state, .denied)
                XCTAssertEqual(handler(for: harness).handle(.init(version: 1, method: "request.status",
                    requestID: ticket.requestID, capability: ticket.capability)), .success(.requestStatus(.denied)))
                XCTAssertEqual(try credentialSnapshot(harness), original)
                XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: write.operationID))
                XCTAssertNil(harness.vault.agentTextWrites.entry(operationID: write.operationID))
                try assertRecordsContainNoExistingIdentity(harness, existing: existing, result: .denied)
            }
        }
    }

    func testApprovedUnavailableNamesFailGenericallyWithoutWritingOrDisclosingIdentity() throws {
        let generic = BrokerRequestHandler(catalog: { _ in [] }, requestStatus: { _, _ in nil },
            commitTextWrite: { _, _, _ in throw VaultError.vaultLocked })
        for recycled in [false, true] {
            for kind in [CredentialPayloadKind.text, .file, .bundle] {
                for action in createActions(named: "café token") {
                    let harness = try makeHarness(authenticate: { _ in true })
                    let existing = try createExisting(harness, kind: kind, permission: recycled ? .allowed : .hidden)
                    if recycled { try harness.vault.deleteTextCredential(id: existing.id, using: .allow) }
                    let original = try credentialSnapshot(harness)
                    let write = AgentTextWriteRequest(operationID: UUID().uuidString, action: action)
                    let ticket = try request(write, in: harness)
                    _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID,
                        capability: ticket.capability, decision: .once)
                    let commit = BrokerRequest(version: 1, method: "credential.write.commit",
                        requestID: ticket.requestID, capability: ticket.capability, textWrite: write)
                    let response = handler(for: harness).handle(commit)
                    XCTAssertEqual(response, .failure(.internalError))
                    XCTAssertEqual(response, generic.handle(commit))
                    for name in [existing.name, "café token", existing.id, "credential_name_conflict"] {
                        XCTAssertFalse(try encoded(response).contains(name))
                    }
                    XCTAssertThrowsError(try harness.vault.commitAgentTextWrite(write,
                        requestID: ticket.requestID, capability: ticket.capability)) { error in
                        guard case VaultError.agentWriteNameUnavailable = error else {
                            return XCTFail("Expected name-free commit failure")
                        }
                        XCTAssertFalse(String(reflecting: error).contains(existing.name))
                        XCTAssertFalse(error.localizedDescription.contains("café"))
                    }
                    XCTAssertEqual(try credentialSnapshot(harness), original)
                    XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: write.operationID))
                    XCTAssertTrue(try harness.vault.brokerCredentialCatalog().isEmpty)
                    try assertRecordsContainNoExistingIdentity(harness, existing: existing, result: .failed)
                }
            }
        }
    }

    func testNameTakenAfterFreezeFailsAtomicallyBeforeCreatingAGroup() throws {
        let harness = try makeHarness(authenticate: { _ in true })
        let write = AgentTextWriteRequest(operationID: UUID().uuidString,
            action: .createBundle(name: "café token", components: [
                .init(name: "token", value: .text("synthetic-replacement"), delivery: .none)
            ], group: "New group"))
        let ticket = try request(write, in: harness)
        let existing = try createExisting(harness, kind: .text, permission: .hidden)
        _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID,
            capability: ticket.capability, decision: .once)
        XCTAssertEqual(handler(for: harness).handle(.init(version: 1, method: "credential.write.commit",
            requestID: ticket.requestID, capability: ticket.capability, textWrite: write)), .failure(.internalError))
        XCTAssertEqual(try harness.vault.listTextCredentials().map(\.id), [existing.id])
        XCTAssertFalse(try harness.vault.listCredentialGroups().contains("New group"))
        XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: write.operationID))
    }

    func testExpiredVisibleNamesStillReturnSpecificError() throws {
        let harness = try makeHarness(authenticate: { _ in true })
        _ = try harness.vault.createTextCredential(.init(name: "Café Token", value: "synthetic-existing",
            permission: .ask, expiresAt: Date(timeIntervalSince1970: 1)), using: .allow)
        XCTAssertEqual(try harness.vault.brokerCredentialCatalog().map(\.expired), [true])
        for action in createActions(named: "Café Token") {
            XCTAssertEqual(response(to: action, handler: handler(for: harness)), .failure(.credentialNameConflict))
        }
    }

    func testVisibilityIsRecheckedAndUnknownPermissionsFailClosed() throws {
        let harness = try makeHarness(authenticate: { _ in true })
        let existing = try createExisting(harness, kind: .text, permission: .ask)
        let handler = handler(for: harness)
        let action = createActions(named: "Café Token")[0]
        XCTAssertEqual(response(to: action, handler: handler), .failure(.credentialNameConflict))
        try harness.vault.updateCredentialPermission(id: existing.id, permission: .hidden, using: .allow)
        XCTAssertTrue(try harness.vault.brokerCredentialCatalog().isEmpty)
        _ = try request(.init(operationID: UUID().uuidString, action: action), in: harness)

        var record = try XCTUnwrap(harness.store.fetchCredential(id: existing.id))
        record.permission = "unknown-permission"
        try harness.store.updateCredential(record)
        XCTAssertThrowsError(try harness.vault.brokerCredentialCatalog())
        XCTAssertEqual(response(to: action, handler: handler), .failure(.internalError))
    }

    private func createExisting(_ harness: Harness, kind: CredentialPayloadKind,
        permission: CredentialPermission) throws -> ManagedTextCredential {
        // Decomposed spelling exercises the same canonical and case folding as creation.
        let name = "Cafe\u{301} Token"
        switch kind {
        case .text:
            return try harness.vault.createTextCredential(.init(name: name, value: "synthetic-existing",
                permission: permission), using: .allow)
        case .file:
            return try harness.vault.createFileCredential(.init(name: name,
                snapshot: .init(originalFilename: "synthetic.txt", bytes: Data("synthetic-file".utf8)),
                permission: permission), using: .allow)
        case .bundle:
            return try harness.vault.createBundleCredential(.init(name: name, components: [
                .init(name: "token", value: .text("synthetic-existing"), delivery: .none)
            ], permission: permission), using: .allow)
        }
    }

    private func createActions(named name: String) -> [AgentTextWriteAction] {
        [.create(name: name, value: "synthetic-replacement"),
         .createBundle(name: name, components: [
            .init(name: "token", value: .text("synthetic-replacement"), delivery: .none)
         ])]
    }

    private func handler(for harness: Harness) -> BrokerRequestHandler {
        .init(catalog: { try harness.vault.brokerCredentialCatalog(cancellation: $0) },
            requestStatus: { try harness.vault.approvalRequests.status(requestID: $0, capability: $1) },
            submitTextWrite: { request, _ in try harness.vault.requestAgentTextWrite(request) },
            commitTextWrite: { try harness.vault.commitAgentTextWrite($0, requestID: $1, capability: $2) })
    }

    private func request(_ write: AgentTextWriteRequest, in harness: Harness) throws -> AgentTextWriteSubmission {
        let response = handler(for: harness).handle(.init(version: 1, method: "credential.write.request", textWrite: write))
        guard case .success(.textWriteRequest(.submitted(let ticket))) = response else {
            XCTFail("Expected normal approval submission")
            throw BrokerApprovalError.invalidDecision
        }
        return ticket
    }

    private func assertRecordsContainNoExistingIdentity(_ harness: Harness, existing: ManagedTextCredential,
        result: CredentialAccessEvent.Result) throws {
        let records = try harness.vault.listCredentialAccessRecords()
        XCTAssertFalse(records.isEmpty)
        XCTAssertTrue(records.allSatisfy { $0.result == result && $0.operation == .create })
        let text = try encoded(records)
        for name in [existing.name, "café token", existing.id] { XCTAssertFalse(text.contains(name)) }
    }

    private func credentialSnapshot(_ harness: Harness) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(harness.store.fetchAllCredentialsIncludingRecycled())
    }

    private func response(to action: AgentTextWriteAction, handler: BrokerRequestHandler) -> BrokerResponse {
        handler.handle(.init(version: BrokerProtocolVersion.current, method: "credential.write.request",
            textWrite: .init(operationID: UUID().uuidString, action: action)))
    }
}
