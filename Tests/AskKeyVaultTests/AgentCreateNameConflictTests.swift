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

    func testHiddenDuplicatesMatchUnrelatedGenericFailuresForBothAgentCreateActions() throws {
        let generic = BrokerRequestHandler(catalog: { _ in [] }, requestStatus: { _, _ in nil },
            submitTextWrite: { _, _ in throw VaultError.vaultLocked })
        for kind in [CredentialPayloadKind.text, .file, .bundle] {
            let harness = try makeHarness(authenticate: { _ in true })
            _ = try createExisting(harness, kind: kind, permission: .hidden)
            let handler = handler(for: harness)
            XCTAssertTrue(try harness.vault.brokerCredentialCatalog().isEmpty)

            for action in createActions(named: "  café token  ") {
                let hidden = response(to: action, handler: handler)
                XCTAssertEqual(hidden, .failure(.internalError))
                XCTAssertEqual(try encoded(hidden), try encoded(response(to: action, handler: generic)))
            }
            XCTAssertTrue(harness.vault.approvalRequests.pendingRequests().isEmpty)
        }
    }

    func testRecycledNamesRetainGenericFailure() throws {
        let harness = try makeHarness(authenticate: { _ in true })
        let existing = try createExisting(harness, kind: .text, permission: .allowed)
        try harness.vault.deleteTextCredential(id: existing.id, using: .allow)
        XCTAssertTrue(try harness.vault.brokerCredentialCatalog().isEmpty)
        for action in createActions(named: "Café Token") {
            XCTAssertEqual(response(to: action, handler: handler(for: harness)), .failure(.internalError))
        }
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
        XCTAssertEqual(response(to: action, handler: handler), .failure(.internalError))

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
            requestStatus: { _, _ in nil },
            submitTextWrite: { request, _ in try harness.vault.requestAgentTextWrite(request) })
    }

    private func response(to action: AgentTextWriteAction, handler: BrokerRequestHandler) -> BrokerResponse {
        handler.handle(.init(version: BrokerProtocolVersion.current, method: "credential.write.request",
            textWrite: .init(operationID: UUID().uuidString, action: action)))
    }
}
