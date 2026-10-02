import XCTest
import AskKeyBroker
@testable import AskKeyCore

final class CredentialAccessRecordTests: XCTestCase {
    func testRecordsAreEncryptedBoundedExpiredAndManagementOnly() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let harness = try makeHarness(now: now)
        let event = CredentialAccessEvent(
            timestamp: now,
            credentialID: "credential-1",
            operation: .runtimeRead,
            result: .allowed,
            callerHint: "cursor",
            declaredPurpose: "deploy"
        )

        harness.vault.recordCredentialAccess(event)
        XCTAssertThrowsError(try harness.vault.listCredentialAccessRecords())
        try harness.vault.beginManagementSession(using: .allow)
        XCTAssertEqual(try harness.vault.listCredentialAccessRecords(), [event])

        let stored = try XCTUnwrap(harness.store.rawCredentialAccessRecords().first)
        for plaintext in ["credential-1", "cursor", "deploy", "runtimeRead", "allowed"] {
            XCTAssertFalse(String(decoding: stored.encryptedRecord, as: UTF8.self).contains(plaintext))
        }

        harness.vault.recordCredentialAccess(.init(
            timestamp: now.addingTimeInterval(-91 * 24 * 60 * 60),
            credentialID: "expired",
            operation: .catalog,
            result: .denied,
            callerHint: nil,
            declaredPurpose: nil
        ))
        for index in 0...CredentialAccessRecordPolicy.maximumEntries {
            harness.vault.recordCredentialAccess(.init(
                timestamp: now.addingTimeInterval(Double(index)),
                credentialID: "id-\(index)",
                operation: .catalog,
                result: .allowed,
                callerHint: nil,
                declaredPurpose: nil
            ))
        }
        let retained = try harness.vault.listCredentialAccessRecords()
        XCTAssertEqual(retained.count, CredentialAccessRecordPolicy.maximumEntries)
        XCTAssertFalse(retained.contains { $0.credentialID == "expired" })
    }

    func testHiddenGuessIsGenericAndWriteFailurePersistsVisibleState() throws {
        let harness = try makeHarness(now: Date(timeIntervalSince1970: 2_000_000_000))
        harness.vault.recordHiddenCredentialGuess(callerHint: "agent", declaredPurpose: "guess")
        try harness.vault.beginManagementSession(using: .allow)
        let event = try XCTUnwrap(harness.vault.listCredentialAccessRecords().first)
        XCTAssertNil(event.credentialID)
        XCTAssertEqual(event.result, .hiddenNameRejected)

        try harness.store.failCredentialAccessRecordWritesForTesting()
        harness.vault.recordCredentialAccess(.init(
            timestamp: Date(), credentialID: "id", operation: .catalog,
            result: .allowed, callerHint: nil, declaredPurpose: nil
        ))
        XCTAssertTrue(try harness.vault.hasCredentialAccessRecordWriteFailure())
    }

    func testRecordsAreAbsentFromSocketAndHelperSurfaces() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = [
            "Sources/AskKeyBroker/BrokerProtocol.swift",
            "Sources/AskKeyHelper/main.swift",
        ]
        for path in paths {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("credential_access_records"), path)
            XCTAssertFalse(source.contains("listCredentialAccessRecords"), path)
            XCTAssertFalse(source.contains("clearCredentialAccessRecords"), path)
        }

        let socket = "/tmp/ak-\(UUID().uuidString.prefix(8)).sock"
        let handler = BrokerRequestHandler(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        let server = BrokerSocketServer(socketPath: socket, handler: handler)
        try server.start()
        defer { server.stop() }
        let client = BrokerSocketClient(socketPath: socket)
        for method in ["access.records", "access.clear", "backup", "restore", "credential.permanent-delete"] {
            XCTAssertEqual(
                try client.send(.init(version: BrokerProtocolVersion.current, method: method)),
                .failure(.methodNotAllowed),
                method
            )
        }
    }

    func testTextWriteRevealRequiresFreshAuthenticationAndDoesNotApprove() throws {
        let harness = try makeHarness(now: Date(timeIntervalSince1970: 2_000_000_000))
        try harness.vault.beginManagementSession(using: .allow)
        let outcome = try harness.vault.requestAgentTextWrite(.init(
            operationID: "write-reveal",
            action: .create(name: "API Key", value: "caller-known-value")
        ))
        guard case .submitted(let ticket) = outcome else { return XCTFail("expected submission") }

        XCTAssertThrowsError(try harness.vault.revealAgentTextWrite(
            operationID: "write-reveal", requestID: ticket.requestID,
            capability: ticket.capability, using: .deny
        ))
        XCTAssertEqual(try harness.vault.revealAgentTextWrite(
            operationID: "write-reveal", requestID: ticket.requestID,
            capability: ticket.capability, using: .allow
        ), .create(name: "API Key", value: "caller-known-value"))
        XCTAssertEqual(
            try harness.vault.approvalRequests.status(
                requestID: ticket.requestID, capability: ticket.capability
            ),
            .pending
        )

        let other = try harness.vault.requestAgentTextWrite(.init(
            operationID: "other-write-reveal",
            action: .create(name: "Other", value: "other-value")
        ))
        guard case .submitted = other else { return XCTFail("expected second submission") }
        XCTAssertThrowsError(try harness.vault.revealAgentTextWrite(
            operationID: "other-write-reveal",
            requestID: ticket.requestID,
            capability: ticket.capability,
            using: .allow
        )) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .payloadMismatch)
        }
    }

    func testHiddenWriteGuessAutomaticallyCreatesGenericRecord() throws {
        let harness = try makeHarness(now: Date(timeIntervalSince1970: 2_000_000_000))
        try harness.vault.beginManagementSession(using: .allow)
        _ = try harness.vault.createTextCredential(
            .init(name: "Hidden", value: "secret", permission: .hidden), using: .allow
        )
        XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(.init(
            operationID: "hidden-guess",
            action: .modify(name: "Hidden", value: "replacement"),
            callerName: "agent",
            callerPurpose: "guess"
        )))
        let event = try XCTUnwrap(harness.vault.listCredentialAccessRecords().first)
        XCTAssertNil(event.credentialID)
        XCTAssertEqual(event.result, .hiddenNameRejected)
    }

    func testHiddenRuntimeGuessNeverRecordsTheGuessedName() throws {
        let harness = try makeHarness(now: Date(timeIntervalSince1970: 2_000_000_000))
        try harness.vault.beginManagementSession(using: .allow)
        _ = try harness.vault.createTextCredential(
            .init(
                name: "Hidden Runtime", value: "secret",
                environmentVariable: "HIDDEN_RUNTIME", permission: .hidden
            ),
            using: .allow
        )
        XCTAssertThrowsError(try harness.vault.brokerTextCredentials(
            for: .init(command: ["/usr/bin/true"], credentialNames: ["Hidden Runtime"]),
            cancellation: BrokerCancellation()
        ))
        let event = try XCTUnwrap(harness.vault.listCredentialAccessRecords().first)
        XCTAssertNil(event.credentialID)
        XCTAssertEqual(event.result, .hiddenNameRejected)
    }

    private func makeHarness(now: Date) throws -> (vault: Vault, store: VaultStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(path: directory.appendingPathComponent("vault.db").path)
        return (
            Vault(
                store: store,
                key: VaultCrypto.generateKey(),
                now: { now },
                approvalRequests: BrokerApprovalStateMachine(authenticate: { _ in true })
            ),
            store
        )
    }
}
