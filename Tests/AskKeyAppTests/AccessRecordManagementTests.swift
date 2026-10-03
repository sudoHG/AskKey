import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyCore

@MainActor
final class AccessRecordManagementTests: AskKeyAppTestCase {
    func testAppLoadsRecordsOnlyInsideManagementSession() {
        let recorder = AccessRecordAppRecorder()
        let viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: CredentialAccessRecordMutations(
                list: { recorder.load() },
                clear: { _ in }
            )
        )

        viewModel.reloadCredentialAccessRecords()
        XCTAssertTrue(viewModel.credentialAccessRecords.isEmpty)
        XCTAssertEqual(recorder.loadCount, 0)

        viewModel.isLocked = false
        viewModel.hasManagementSession = true
        viewModel.reloadCredentialAccessRecords()
        XCTAssertEqual(viewModel.credentialAccessRecords, [recorder.event])
        XCTAssertEqual(recorder.loadCount, 1)
        XCTAssertEqual(recorder.clearAttempts, 0)

        viewModel.endManagementSession()
        XCTAssertTrue(viewModel.credentialAccessRecords.isEmpty)
    }

    func testAppClearPassesFreshAuthenticationAndReloads() async {
        let recorder = AccessRecordAppRecorder()
        let viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: CredentialAccessRecordMutations(
                list: { recorder.load() },
                clear: { authenticator in
                    try recorder.clear(authenticator: authenticator)
                }
            ),
            authenticateCredentialAccessRecordClear: { reason in
                recorder.authenticate(reason: reason)
            }
        )
        await viewModel.clearCredentialAccessRecords()
        XCTAssertEqual(recorder.authenticationAttempts, 0)
        XCTAssertEqual(recorder.clearAttempts, 0)

        viewModel.isLocked = false
        viewModel.hasManagementSession = true
        viewModel.reloadCredentialAccessRecords()

        await viewModel.clearCredentialAccessRecords()
        XCTAssertEqual(viewModel.credentialAccessRecords, [recorder.event])
        XCTAssertEqual(recorder.authenticationAttempts, 1)
        XCTAssertEqual(recorder.clearAttempts, 1)
        XCTAssertEqual(recorder.clearSuccesses, 0)

        await viewModel.clearCredentialAccessRecords()
        XCTAssertTrue(viewModel.credentialAccessRecords.isEmpty)
        XCTAssertEqual(recorder.authenticationAttempts, 2)
        XCTAssertEqual(recorder.clearAttempts, 2)
        XCTAssertEqual(recorder.clearSuccesses, 1)
    }

    func testProductionAppDefaultsCallCoreListAndClearAPIs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let viewModel = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyAppKit/VaultViewModel.swift"),
            encoding: .utf8
        )
        let mutations = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyAppKit/CredentialWorkspaceMutations.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(viewModel.contains("listCredentialAccessRecords:"))
        XCTAssertFalse(viewModel.contains("clearCredentialAccessRecords:"))
        XCTAssertFalse(viewModel.contains("accessRecords: CredentialAccessRecordMutations = .live"))
        XCTAssertTrue(viewModel.contains("accessRecords ?? credentialMutations.accessRecords"))
        XCTAssertTrue(mutations.contains("accessRecords: .live"))
        XCTAssertTrue(mutations.contains("accessRecords: .readOnly { [] }"))
        XCTAssertTrue(mutations.contains("Vault.shared.listCredentialAccessRecords"))
        XCTAssertTrue(mutations.contains("Vault.shared.clearCredentialAccessRecords"))
        XCTAssertFalse(viewModel.contains("storedCredentialCount: @escaping () throws -> Int = {"))
        XCTAssertTrue(viewModel.contains("storedCredentialCountImpl = credentialMutations.storedCredentialCount"))
        XCTAssertTrue(mutations.contains("storedCredentialCount: { try Vault.shared.storedCredentialCount() }"))
    }
}

private final class AccessRecordAppRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var loadCount = 0
    private(set) var clearAttempts = 0
    private(set) var clearSuccesses = 0
    private(set) var authenticationAttempts = 0
    private var cleared = false
    let event = CredentialAccessEvent(
        timestamp: Date(timeIntervalSince1970: 2_000_000_000),
        credentialID: "credential",
        operation: .runtimeRead,
        result: .allowed,
        callerHint: "agent",
        declaredPurpose: "deploy"
    )

    func load() -> [CredentialAccessEvent] {
        lock.lock(); defer { lock.unlock() }
        loadCount += 1
        return cleared ? [] : [event]
    }

    func clear(authenticator: ManagementAuthenticator) throws {
        lock.lock(); defer { lock.unlock() }
        clearAttempts += 1
        guard authenticator.confirm(reason: "test") else {
            throw VaultError.managementAuthenticationRequired
        }
        clearSuccesses += 1
        cleared = true
    }

    func authenticate(reason: String) -> ManagementAuthenticator {
        lock.lock(); defer { lock.unlock() }
        authenticationAttempts += 1
        XCTAssertEqual(reason, "Clear Ask Key access records")
        return authenticationAttempts == 1 ? .deny : .allow
    }
}
