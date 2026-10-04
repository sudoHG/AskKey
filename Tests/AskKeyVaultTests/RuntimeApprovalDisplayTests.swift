import CryptoKit
import Foundation
import XCTest
@testable import AskKeyBroker
@testable import AskKeyVault

final class RuntimeApprovalDisplayTests: XCTestCase {
    func testDisplayAndDigestComeFromSameDecodedRequestWithoutInheritedEnvironment() throws {
        let harness = try makeHarness()
        _ = try createCredential(.text, in: harness)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let request = BrokerTextRunRequest(
            operationID: "decoded-display", command: ["/opt/synthetic/deploy.sh", "two words", "it's", ""],
            credentialNames: ["Synthetic"], workingDirectory: home + "/synthetic",
            inheritedEnvironment: ["HOME": "/synthetic-untrusted-home", "TOKEN": "synthetic-inherited-secret"],
            callerName: "synthetic caller", callerPurpose: "synthetic purpose"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(request)
        let decoded = try JSONDecoder().decode(BrokerTextRunRequest.self, from: encoded)
        _ = try pendingTickets(decoded, in: harness)
        let approval = try XCTUnwrap(harness.approvals.pendingRequests().first?.request)
        let display = try XCTUnwrap(approval.display)
        XCTAssertEqual(display.commandLine, "/opt/synthetic/deploy.sh 'two words' 'it'\\''s' ''")
        XCTAssertEqual(display.commandSummary, display.commandLine)
        XCTAssertEqual(display.workingDirectory, "~/synthetic")
        XCTAssertEqual(display.executableBasename, "deploy.sh")
        XCTAssertEqual(display.environmentVariables, ["TOKEN"])
        XCTAssertEqual(display.temporaryFileVariables, [])
        XCTAssertEqual(approval.payloadDigest, SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined())
        for privateText in ["synthetic-inherited-secret", "synthetic-untrusted-home", "synthetic-value"] {
            XCTAssertFalse(String(describing: display).contains(privateText))
        }
    }

    func testFileNamesComeFromMetadataAndBundleNamesRemainUnavailable() throws {
        for kind in [CredentialPayloadKind.file, .bundle] {
            let harness = try makeHarness()
            _ = try createCredential(kind, in: harness)
            _ = try pendingTickets(request(), in: harness)
            let display = try XCTUnwrap(harness.approvals.pendingRequests().first?.request.display)
            XCTAssertEqual(display.commandLine, "/opt/synthetic/deploy.sh")
            if kind == .file {
                XCTAssertEqual(display.environmentVariables, [])
                XCTAssertEqual(display.temporaryFileVariables, ["KEY_FILE"])
            } else {
                XCTAssertNil(display.environmentVariables)
                XCTAssertNil(display.temporaryFileVariables)
            }
            XCTAssertFalse(String(describing: display).contains("synthetic-private-filename"))
            XCTAssertFalse(String(describing: display).contains("synthetic-value"))
        }
    }

    func testAbsentMappingIsEmptyRatherThanUnavailable() throws {
        let harness = try makeHarness()
        _ = try harness.vault.createTextCredential(.init(name: "Synthetic", value: "synthetic-value", permission: .ask),
                                                   using: .allow)
        _ = try pendingTickets(request(), in: harness)
        let display = try XCTUnwrap(harness.approvals.pendingRequests().first?.request.display)
        XCTAssertEqual(display.environmentVariables, [])
        XCTAssertEqual(display.temporaryFileVariables, [])
    }

    func testDirectoryAbbreviatesOnlyWholeHomePrefixAndEscapesControls() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let examples: [(String?, String?)] = [
            (nil, nil), (home, "~"), (home + "/project", "~/project"),
            (home + "-other/project", home + "-other/project"),
            (home + "/line\n\r\t\u{1b}\u{2028}\\n", "~/line\\n\\r\\t\\x1b\\xe2\\x80\\xa8\\\\n"),
        ]
        for (directory, expected) in examples {
            let harness = try makeHarness()
            _ = try createCredential(.text, in: harness)
            _ = try pendingTickets(request(directory: directory), in: harness)
            XCTAssertEqual(harness.approvals.pendingRequests().first?.request.display?.workingDirectory, expected)
        }
    }

    func testShellQuotingEscapesControlsAndRoundTripsExactArguments() throws {
        let harness = try makeHarness()
        _ = try createCredential(.text, in: harness)
        let arguments = [
            "/opt/synthetic/deploy.sh", "", "two words", "it's", "double\"quote", "\\n",
            "$(printf injected)", "`printf injected`", "; printf injected", "*", "line\nnext",
            "line\r\t\u{1b}\u{7f}\u{85}\u{2028}\u{2029}\u{202e}\u{e0001}", "quote'\\\n", "🙂",
        ]
        _ = try pendingTickets(request(command: arguments), in: harness)
        let display = try XCTUnwrap(harness.approvals.pendingRequests().first?.request.display)
        XCTAssertTrue(display.commandLine.contains("$'line\\nnext'"))
        XCTAssertTrue(display.commandLine.contains("\\x1b"))
        XCTAssertTrue(display.commandLine.contains("\\xe2\\x80\\xae"))
        XCTAssertFalse(display.commandLine.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "printf '%s\\0' " + display.commandLine]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let decoded = bytes.split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
            String(decoding: $0, as: UTF8.self)
        }
        XCTAssertEqual(decoded, arguments)
    }

    func testAskValuesAreNotDecryptedUntilApprovalForEveryPayloadKind() throws {
        for kind in [CredentialPayloadKind.text, .file, .bundle] {
            let harness = try makeHarness()
            let created = try createCredential(kind, in: harness)
            try poisonPayload(id: created.id, in: harness)
            let request = request()
            let tickets = try pendingTickets(request, in: harness)
            XCTAssertEqual(tickets.count, 1, "a poisoned value must not prevent pre-approval display: \(kind)")
            XCTAssertNotNil(harness.approvals.pendingRequests().first?.request.display)
            try approve(tickets, in: harness)
            XCTAssertThrowsError(try harness.vault.brokerTextCredentials(for: request, cancellation: .init()),
                                 "the poisoned payload must be opened only after approval: \(kind)")
        }
    }

    func testPartiallyApprovedBatchDoesNotDecryptAskOrAllowedPayloads() throws {
        for permission in [CredentialPermission.ask, .allowed] {
            let harness = try makeHarness()
            let first = try createCredential(.text, in: harness, name: "First", permission: permission)
            _ = try createCredential(.file, in: harness, name: "Second")
            try poisonPayload(id: first.id, in: harness)
            let request = request(names: ["First", "Second"])
            let tickets = try pendingTickets(request, in: harness)
            if permission == .ask {
                try approve([tickets[0]], in: harness)
                XCTAssertEqual(try pendingTickets(request, in: harness).count, 1)
            }
            try approve([tickets.last!], in: harness)
            XCTAssertThrowsError(try harness.vault.brokerTextCredentials(for: request, cancellation: .init()))
        }
    }

    func testDifferentRuntimeRequestStillFailsExistingDigestCheck() throws {
        let harness = try makeHarness()
        _ = try createCredential(.text, in: harness)
        let original = request(operationID: "frozen-command", command: ["/opt/synthetic/deploy.sh", "first"])
        let tickets = try pendingTickets(original, in: harness)
        let variants = [
            request(operationID: original.operationID, command: ["/opt/synthetic/other.sh", "first"]),
            request(operationID: original.operationID, command: ["/opt/synthetic/deploy.sh", "changed"]),
            request(operationID: original.operationID, command: original.command, directory: "/synthetic/other"),
            request(operationID: original.operationID, command: original.command, environment: ["LANG": "C"]),
        ]
        for approved in [false, true] {
            if approved { try approve(tickets, in: harness) }
            for changed in variants {
                XCTAssertThrowsError(try harness.vault.brokerTextCredentials(for: changed, cancellation: .init())) {
                    XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch)
                }
            }
        }
        guard case .resolved(let credentials, _, let lease) = try harness.vault.brokerTextCredentials(
            for: original, cancellation: .init()
        ) else { return XCTFail("the original approval must remain usable") }
        defer { lease?.finish(); lease?.cleanup() }
        XCTAssertEqual(credentials, [.init(environmentVariable: "TOKEN", value: "synthetic-value")])
    }

    func testAccessRecordsPersistOnlyExecutableBasenameForAllowDenyAndFailure() throws {
        for result in [CredentialAccessEvent.Result.allowed, .denied, .failed] {
            let harness = try makeHarness()
            let expires = result == .failed ? Date(timeIntervalSince1970: 1) : nil
            _ = try harness.vault.createTextCredential(
                .init(name: "Synthetic", value: "synthetic-value", environmentVariable: "TOKEN",
                      permission: result == .denied ? .ask : .allowed, expiresAt: expires), using: .allow
            )
            let request = request(command: ["/opt/synthetic/deploy.sh", "synthetic-private-argument"],
                                  directory: "/synthetic-private-directory", environment: ["LANG": "synthetic-private-environment"])
            if result == .failed {
                XCTAssertThrowsError(try harness.vault.brokerTextCredentials(for: request, cancellation: .init()))
            } else if result == .denied {
                let ticket = try XCTUnwrap(try pendingTickets(request, in: harness).first)
                _ = try harness.approvals.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .deny)
                harness.approvals.flushObservers()
            } else {
                guard case .resolved(_, _, let lease) = try harness.vault.brokerTextCredentials(
                    for: request, cancellation: .init()
                ) else { return XCTFail("allowed credential should resolve") }
                lease?.finish(); lease?.cleanup()
            }
            let records = try harness.vault.listCredentialAccessRecords().filter { $0.operation == .runtimeRead }
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.result, result)
            XCTAssertEqual(records.first?.executableBasename, "deploy.sh")
            let plaintext = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
            for forbidden in ["/opt/synthetic", "synthetic-private-argument", "synthetic-private-directory",
                              "synthetic-private-environment", "synthetic-value", "TOKEN"] {
                XCTAssertFalse(plaintext.contains(forbidden))
            }
        }
    }

    func testExecutableBasenameEscapesNewlineAndBidirectionalControlsBeforeDisplayAndStorage() throws {
        for denied in [false, true] {
            let harness = try makeHarness()
            _ = try createCredential(.text, in: harness)
            let request = request(command: ["/opt/synthetic/deploy\n\u{202e}.sh"])
            let ticket = try XCTUnwrap(try pendingTickets(request, in: harness).first)
            let display = try XCTUnwrap(harness.approvals.pendingRequests().first?.request.display)
            let expected = "deploy\\n\\xe2\\x80\\xae.sh"
            XCTAssertEqual(display.executableBasename, expected)
            _ = try harness.approvals.decide(requestID: ticket.requestID, capability: ticket.capability,
                                             decision: denied ? .deny : .once)
            if denied {
                harness.approvals.flushObservers()
            } else {
                guard case .resolved(_, _, let lease) = try harness.vault.brokerTextCredentials(
                    for: request, cancellation: .init()
                ) else { return XCTFail("approved credential should resolve") }
                lease?.finish(); lease?.cleanup()
            }
            let event = try XCTUnwrap(harness.vault.listCredentialAccessRecords().first)
            XCTAssertEqual(event.executableBasename, expected)
            XCTAssertEqual(event.result, denied ? .denied : .allowed)
            XCTAssertFalse(expected.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        }
    }

    func testExecutableBasenameIsBoundedBeforeDisplayAndStorageWithFullCommandRetained() throws {
        let harness = try makeHarness()
        _ = try createCredential(.text, in: harness)
        let basename = String(repeating: "a", count: 80) + "\n\u{202e}" + String(repeating: "z", count: 80)
        let request = request(command: ["/opt/synthetic/" + basename])
        let tickets = try pendingTickets(request, in: harness)
        let display = try XCTUnwrap(harness.approvals.pendingRequests().first?.request.display)
        let expected = String(repeating: "a", count: 32) + "…" + String(repeating: "z", count: 31)
        XCTAssertEqual(display.executableBasename, expected)
        XCTAssertEqual(display.executableBasename?.count, 64)
        XCTAssertTrue(display.commandLine.contains(String(repeating: "a", count: 80)))
        XCTAssertTrue(display.commandLine.contains("\\n\\xe2\\x80\\xae"))
        try approve(tickets, in: harness)
        guard case .resolved(_, _, let lease) = try harness.vault.brokerTextCredentials(
            for: request, cancellation: .init()
        ) else { return XCTFail("approved credential should resolve") }
        defer { lease?.finish(); lease?.cleanup() }
        XCTAssertEqual(try harness.vault.listCredentialAccessRecords().first?.executableBasename, expected)
    }

    func testOldAccessRecordsDecodeWithoutExecutableAndNewRecordsStripPath() throws {
        let event = CredentialAccessEvent(timestamp: Date(timeIntervalSince1970: 0), credentialID: "synthetic",
                                          operation: .runtimeRead, result: .allowed, callerHint: nil,
                                          declaredPurpose: nil, executableBasename: "/opt/synthetic/deploy.sh")
        XCTAssertEqual(event.executableBasename, "deploy.sh")
        let encoded = try JSONEncoder().encode(event)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "executableBasename")
        XCTAssertNil(try JSONDecoder().decode(CredentialAccessEvent.self,
                                              from: JSONSerialization.data(withJSONObject: old)).executableBasename)
    }

    private func request(
        operationID: String = UUID().uuidString, command: [String] = ["/opt/synthetic/deploy.sh"],
        names: [String] = ["Synthetic"], directory: String? = nil, environment: [String: String] = [:]
    ) -> BrokerTextRunRequest {
        .init(operationID: operationID, command: command, credentialNames: names,
              workingDirectory: directory, inheritedEnvironment: environment)
    }

    private func pendingTickets(_ request: BrokerTextRunRequest, in harness: Harness) throws -> [BrokerApprovalTicket] {
        guard case .approvalRequired(let tickets) = try harness.vault.brokerTextCredentials(
            for: request, cancellation: .init()
        ) else { throw NSError(domain: "RuntimeApprovalDisplayTests", code: 1) }
        return tickets
    }

    private func approve(_ tickets: [BrokerApprovalTicket], in harness: Harness) throws {
        for ticket in tickets {
            _ = try harness.approvals.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        }
    }

    private func poisonPayload(id: String, in harness: Harness) throws {
        var record = try XCTUnwrap(harness.store.fetchCredential(id: id))
        record.encryptedPayload = Data("synthetic-invalid-ciphertext".utf8)
        // Re-seal the record MAC so authentication succeeds. Only attempting
        // value decryption will fail; this is the pre-approval decryption tripwire.
        try harness.store.updateCredential(record)
    }

    private func createCredential(
        _ kind: CredentialPayloadKind, in harness: Harness, name: String = "Synthetic",
        permission: CredentialPermission = .ask
    ) throws -> ManagedTextCredential {
        switch kind {
        case .text:
            return try harness.vault.createTextCredential(
                .init(name: name, value: "synthetic-value", environmentVariable: "TOKEN", permission: permission), using: .allow)
        case .file:
            return try harness.vault.createFileCredential(
                .init(name: name, snapshot: try .init(originalFilename: "synthetic-private-filename",
                                                     bytes: Data("synthetic-value".utf8)),
                      environmentVariable: "KEY_FILE", permission: permission), using: .allow)
        case .bundle:
            return try harness.vault.createBundleCredential(
                .init(name: name, components: [
                    .init(name: "TOKEN", value: .text("synthetic-value"), delivery: .environmentVariable("TOKEN")),
                    .init(name: "KEY_FILE", value: .file(filename: "synthetic-private-filename", bytes: Data("synthetic-value".utf8)),
                          delivery: .temporaryFile("KEY_FILE")),
                ], permission: permission), using: .allow)
        }
    }

    private typealias Harness = (vault: Vault, store: VaultStore, approvals: BrokerApprovalStateMachine)

    private func makeHarness() throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyApprovalDisplay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let store = try VaultStore(path: root.appendingPathComponent("synthetic.db").path)
        let approvals = BrokerApprovalStateMachine(authenticate: { _ in true })
        let manager = try FileDeliveryManager(rootURL: root.appendingPathComponent("deliveries"))
        let vault = Vault(store: store, key: VaultCrypto.generateKey(), approvalRequests: approvals, fileDeliveryManager: manager)
        try vault.beginManagementSession(using: .allow)
        addTeardownBlock {
            approvals.flushObservers()
            manager.cleanupAll()
            try store.close()
            try FileManager.default.removeItem(at: root)
        }
        return (vault, store, approvals)
    }
}
