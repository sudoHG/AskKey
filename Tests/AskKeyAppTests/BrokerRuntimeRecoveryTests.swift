import Foundation
import XCTest
@testable import AskKeyApp
@testable import AskKeyBroker
@testable import AskKeyCore

@MainActor
final class BrokerRuntimeRecoveryTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AskKey.broker-recovery.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTypedStagingFailuresHaveSanitizedNextSteps() {
        let typeFailure = BrokerRuntimeFailure.userFacing(for: BrokerFileWriteError.stagingNotADirectory)
        XCTAssertTrue(typeFailure.canRetry)
        XCTAssertTrue(typeFailure.message.contains("file"))
        XCTAssertTrue(typeFailure.message.lowercased().contains("retry"))
        XCTAssertFalse(typeFailure.message.contains(NSHomeDirectory()))
        XCTAssertFalse(typeFailure.message.contains("file-write-staging"))

        let permissionFailure = BrokerRuntimeFailure.userFacing(for: BrokerFileWriteError.stagingPermissionDenied)
        XCTAssertTrue(permissionFailure.canRetry)
        XCTAssertTrue(permissionFailure.message.lowercased().contains("permission"))
        XCTAssertTrue(permissionFailure.message.lowercased().contains("retry"))
        XCTAssertFalse(permissionFailure.message.contains(NSHomeDirectory()))
        XCTAssertNotEqual(typeFailure.message, permissionFailure.message)
    }

    func testRecoveryDoesNotStartASecondBroker() {
        var starts = 0
        var running = false
        var recovery = BrokerRuntimeRecovery(
            isRunning: { running },
            start: {
                starts += 1
                running = true
            }
        )

        XCTAssertTrue(recovery.retry())
        XCTAssertEqual(starts, 1)
        XCTAssertFalse(recovery.retry())
        XCTAssertEqual(starts, 1)
    }

    func testRecoveryStartsOnlyAfterTheDirectoryConditionIsFixed() {
        var starts = 0
        var blocked = true
        var recovery = BrokerRuntimeRecovery(
            isRunning: { false },
            start: {
                if blocked { throw BrokerFileWriteError.stagingNotADirectory }
                starts += 1
            }
        )

        XCTAssertFalse(recovery.retry())
        XCTAssertEqual(starts, 0)
        blocked = false
        XCTAssertTrue(recovery.retry())
        XCTAssertEqual(starts, 1)
    }

    func testDismissingThePromptKeepsARecoveryEntryAfterReopen() throws {
        let runtime = try makeBlockedRuntime()
        defer { runtime.stop() }
        let expected = "Ask Key could not start Agent access because the secure staging folder is a file. Remove that file, then retry."

        runtime.start()
        XCTAssertTrue(runtime.vault.brokerRecoveryAvailable)
        XCTAssertEqual(runtime.vault.errorMessage, expected)
        XCTAssertEqual(runtime.vault.brokerFailureMessage, expected)

        runtime.vault.errorMessage = nil
        runtime.vault.refreshAgentAccessPauseState()

        XCTAssertNil(runtime.vault.errorMessage)
        XCTAssertTrue(runtime.vault.brokerRecoveryAvailable)
        XCTAssertEqual(runtime.vault.brokerFailureMessage, expected)
        XCTAssertNil(runtime.server)
    }

    func testSuccessfulRetryClearsThisBrokerFailureAndLeavesOtherErrors() throws {
        let runtime = try makeBlockedRuntime()
        defer { runtime.stop() }
        let otherError = "Ask Key could not save an access record. Credential operations continue, and this warning will remain until recording succeeds."

        runtime.start()
        runtime.vault.errorMessage = nil
        runtime.vault.errorMessage = otherError
        try FileManager.default.removeItem(at: runtime.stagingURL)

        runtime.vault.retryBrokerRecovery()

        XCTAssertNotNil(runtime.server)
        XCTAssertFalse(runtime.vault.brokerRecoveryAvailable)
        XCTAssertNil(runtime.vault.brokerFailureMessage)
        XCTAssertEqual(runtime.vault.errorMessage, otherError)
        XCTAssertEqual(
            try BrokerSocketClient(socketPath: runtime.socketURL.path).send(.init(version: 1, method: "health")),
            .success(.health(.init(version: BrokerProtocolVersion.current, status: "ok")))
        )
        XCTAssertEqual(runtime.startAttempts, 2)

        runtime.vault.retryBrokerRecovery()
        XCTAssertEqual(runtime.startAttempts, 2)
        XCTAssertEqual(runtime.vault.errorMessage, otherError)
        XCTAssertFalse(runtime.vault.brokerRecoveryAvailable)
    }

    func testFailedRetryKeepsTheRecoveryEntry() throws {
        let runtime = try makeBlockedRuntime()
        defer { runtime.stop() }
        let expected = "Ask Key could not start Agent access because the secure staging folder is a file. Remove that file, then retry."

        runtime.start()
        runtime.vault.errorMessage = nil
        runtime.vault.retryBrokerRecovery()

        XCTAssertNil(runtime.server)
        XCTAssertTrue(runtime.vault.brokerRecoveryAvailable)
        XCTAssertEqual(runtime.vault.brokerFailureMessage, expected)
        XCTAssertEqual(runtime.vault.errorMessage, expected)
        XCTAssertEqual(runtime.startAttempts, 2)
    }

    func testSuccessfulRetryClearsOnlyTheMatchingBrokerError() throws {
        let runtime = try makeBlockedRuntime()
        defer { runtime.stop() }
        let brokerFailure = "Ask Key could not start Agent access because the secure staging folder is a file. Remove that file, then retry."

        runtime.start()
        XCTAssertEqual(runtime.vault.errorMessage, brokerFailure)
        try FileManager.default.removeItem(at: runtime.stagingURL)
        runtime.vault.retryBrokerRecovery()

        XCTAssertNotNil(runtime.server)
        XCTAssertNil(runtime.vault.errorMessage)
        XCTAssertNil(runtime.vault.brokerFailureMessage)
        XCTAssertFalse(runtime.vault.brokerRecoveryAvailable)
    }

    func testMenuAndSettingsKeepRecoveryOutsideTheDismissableError() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyApp/AskKeyApp.swift"), encoding: .utf8
        )
        let start = try XCTUnwrap(app.range(of: "private func startBroker()"))
        let launch = String(app[start.lowerBound...])
        let prepare = try XCTUnwrap(launch.range(of: "try Vault.shared.prepareAgentRuntime()"))
        let coordinator = try XCTUnwrap(launch.range(of: "fileWrites = try BrokerFileWriteCoordinator("))
        let listen = try XCTUnwrap(launch.range(of: "try server.start()"))
        XCTAssertLessThan(prepare.lowerBound, coordinator.lowerBound)
        XCTAssertLessThan(coordinator.lowerBound, listen.lowerBound)
        let failure = String(launch[prepare.upperBound..<coordinator.lowerBound])
        XCTAssertTrue(failure.contains("brokerServer?.stop()"))
        XCTAssertTrue(failure.contains("brokerServer = nil"))
        XCTAssertTrue(failure.contains("return"))

        let popover = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyApp/Views/VaultPopover.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            popover.contains("menuEntry(appLocalized(\"Retry Agent access\")"),
            "menu recovery must stay as its own row after the error banner is closed"
        )

        let settings = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyApp/Views/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(settings.contains("Retry Agent access"))
        let strip = try XCTUnwrap(settings.range(of: "brokerRecoveryStrip"))
        let alert = try XCTUnwrap(settings.range(of: ".alert("))
        XCTAssertLessThan(
            strip.lowerBound,
            alert.lowerBound,
            "settings recovery must remain after the error alert is dismissed"
        )

        XCTAssertTrue(app.contains("vault.clearBrokerRuntimeFailure()"))
        XCTAssertTrue(app.contains("vault.presentBrokerRuntimeFailure("))
        XCTAssertFalse(app.contains("vault.brokerRecoveryAvailable = false"))
    }

    private func makeBlockedRuntime() throws -> IsolatedBrokerRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ak\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let vault = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in },
            unlockVault: {},
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            credentialMutations: .readOnly { ([], [], [], false) }
        )
        let runtime = IsolatedBrokerRuntime(vault: vault, directory: directory)
        try Data("not-a-directory".utf8).write(to: runtime.stagingURL)
        return runtime
    }
}

@MainActor
private final class IsolatedBrokerRuntime {
    private(set) var server: BrokerSocketServer?
    private(set) var startAttempts = 0
    let vault: VaultViewModel
    let stagingURL: URL
    let socketURL: URL

    init(vault: VaultViewModel, directory: URL) {
        self.vault = vault
        stagingURL = directory.appendingPathComponent("file-write-staging")
        socketURL = directory.appendingPathComponent("b.sock")
        vault.retryBrokerStart = { [weak self] in
            self?.retry()
        }
    }

    func start() {
        guard server == nil else { return }
        startAttempts += 1
        do {
            try BrokerRuntimeDirectory.prepareStagingDirectory(stagingURL)
            let server = BrokerSocketServer(
                socketPath: socketURL.path,
                handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil })
            )
            try server.start()
            self.server = server
            vault.clearBrokerRuntimeFailure()
        } catch {
            vault.presentBrokerRuntimeFailure(error)
        }
    }

    func retry() {
        var recovery = BrokerRuntimeRecovery(
            isRunning: { self.server != nil },
            start: {
                self.start()
                if self.server == nil, self.vault.brokerRecoveryAvailable {
                    throw BrokerFileWriteError.stagingFailed
                }
            }
        )
        _ = recovery.retry()
    }

    func stop() {
        server?.stop()
        server = nil
    }
}
