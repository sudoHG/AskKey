import Darwin
import Foundation
import XCTest
@testable import AskKeyAppKit
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeyVault
@testable import AskKeyTestSupport

@MainActor
final class AgentClientConnectorTests: AskKeyAppTestCase {
#if DEBUG
    func testDebugClientE2ERequestRequiresAnIsolatedHome() throws {
        let actualHome = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-e2e-\(UUID().uuidString)", isDirectory: true)
        let isolatedHome = root.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: isolatedHome.path
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let output = isolatedHome.appendingPathComponent("result.json")
        let environment = [
            "ASKKEY_CLIENT_E2E": "codex",
            "ASKKEY_CLIENT_E2E_HOME": isolatedHome.path,
            "ASKKEY_CLIENT_E2E_OUTPUT": output.path,
        ]

        let request = DebugClientE2ERequest.parse(
            environment: environment,
            actualHome: actualHome
        )
        XCTAssertEqual(request?.client, .codex)
        XCTAssertEqual(request?.home, isolatedHome)
        XCTAssertEqual(request?.output, output)

        var unsafe = environment
        unsafe["ASKKEY_CLIENT_E2E_HOME"] = actualHome.path
        XCTAssertNil(DebugClientE2ERequest.parse(
            environment: unsafe,
            actualHome: actualHome
        ))

        let linkedHome = root.appendingPathComponent("linked-home", isDirectory: true)
        try? FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: actualHome)
        unsafe["ASKKEY_CLIENT_E2E_HOME"] = linkedHome.path
        unsafe["ASKKEY_CLIENT_E2E_OUTPUT"] = linkedHome.appendingPathComponent("result.json").path
        XCTAssertNil(DebugClientE2ERequest.parse(
            environment: unsafe,
            actualHome: actualHome
        ))

        unsafe["ASKKEY_CLIENT_E2E_HOME"] = isolatedHome.path
        unsafe["ASKKEY_CLIENT_E2E_OUTPUT"] = isolatedHome
            .appendingPathComponent("missing/result.json").path
        XCTAssertNil(DebugClientE2ERequest.parse(
            environment: unsafe,
            actualHome: actualHome
        ))
    }

    func testDebugClientE2EFalseResultRecordsFailureAndRollback() {
        let result = DebugClientE2EResult.completed(client: .cursor, connected: false)

        XCTAssertFalse(result.connected)
        XCTAssertEqual(result.rollback, "completed")
        XCTAssertNotNil(result.error)
    }
#endif

    func testEverySupportedClientUsesAutomaticConnection() {
        XCTAssertTrue(AgentClient.allCases.allSatisfy(\.isAutomatic))
    }

    func testAutomaticClientPreviewsExplainBackupWriteAndVerificationWithoutRawConfig() {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        AppLanguage.current = "en"

        for client in [AgentClient.codex, .cursor, .grok] {
            let summary = client.connectionPreviewSummary

            XCTAssertTrue(summary.contains("back up"), "\(client.rawValue): \(summary)")
            XCTAssertTrue(summary.contains("add Ask Key"), "\(client.rawValue): \(summary)")
            XCTAssertTrue(summary.contains("verify"), "\(client.rawValue): \(summary)")
            XCTAssertFalse(summary.contains("--- before"))
            XCTAssertFalse(summary.contains("+++ after"))
            XCTAssertFalse(summary.contains("[skills.config]"))
            XCTAssertFalse(summary.contains("{"))
        }
    }

    func testActiveManagementSessionConnectsWithoutAnotherAuthentication() async {
        var authenticationRequests = 0
        let viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            authenticateDeviceOwner: { _ in
                authenticationRequests += 1
                return .allow
            }
        )
        viewModel.isLocked = false
        viewModel.hasManagementSession = true

        let connected = await viewModel.connectAgentClient { true }

        XCTAssertEqual(connected, true)
        XCTAssertEqual(authenticationRequests, 0)
    }

    func testUnknownCodexVersionDoesNotTellNewerClientsToUpgrade() {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        for language in ["zh-Hans", "en"] {
            AppLanguage.current = language
            let message = AgentClientErrorCopy.message(for: .codex, error: CodexUserMCPError.unknownCodexVersion)
            XCTAssertFalse(message.contains("升级"))
            XCTAssertFalse(message.contains("Update Codex"))
            XCTAssertTrue(message.contains(language == "en" ? "compatibility" : "兼容性"))
        }
    }

    func testClientVerificationFailureUsesOneHumanNextStepWithoutInternalReason() async {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        let suiteName = "AgentClientVerification-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.languageMode = "zh-Hans"
        let viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            preferences: preferences
        )
        viewModel.isLocked = false
        viewModel.hasManagementSession = true

        let connected = await viewModel.connectAgentClient(.grok) {
            throw GrokCLIAdapterError.verificationFailed("helper_signature_internal_401")
        }

        XCTAssertNil(connected)
        XCTAssertEqual(
            viewModel.errorMessage,
            "请旨助手的签名或版本不匹配。请重新安装请旨，再重试。"
        )
        XCTAssertFalse(viewModel.errorMessage?.contains("401") == true)
    }

    func testFalseClientVerificationExplainsTheSingleRetryAction() async {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        let suiteName = "FalseClientVerification-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.languageMode = "zh-Hans"
        let viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            preferences: preferences
        )
        viewModel.isLocked = false
        viewModel.hasManagementSession = true

        let connected = await viewModel.connectAgentClient(.cursor) { false }

        XCTAssertNil(connected)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Cursor 没有完成连接检测。请重启 Cursor，再重试。"
        )
    }

    func testLockedVaultDoesNotWriteClientConfigurationWithAStaleManagementFlag() async {
        let connectionAttempts = ConnectionAttemptProbe()
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })
        viewModel.isLocked = true
        viewModel.hasManagementSession = true

        let connected = await viewModel.connectAgentClient {
            connectionAttempts.record()
            return true
        }

        XCTAssertNil(connected)
        XCTAssertEqual(connectionAttempts.count, 0)
    }

    func testExpiredManagementSessionDoesNotWriteClientConfiguration() async {
        let connectionAttempts = ConnectionAttemptProbe()
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })
        viewModel.hasManagementSession = false

        let connected = await viewModel.connectAgentClient {
            connectionAttempts.record()
            return true
        }

        XCTAssertNil(connected)
        XCTAssertEqual(connectionAttempts.count, 0)
        XCTAssertEqual(
            viewModel.errorMessage,
            appLocalized("Credential management requires confirmation before it can continue.")
        )
    }

    func testLockedApprovalUsesOnlyGenericReminderUntilScreenUnlocks() {
        XCTAssertEqual(
            AgentApprovalPrivacyPolicy.plan(screenState: .locked, language: "en"),
            .lockedReminder(
                title: "Ask Key has pending requests",
                body: "Unlock your Mac to review a pending request."
            )
        )
        XCTAssertEqual(
            AgentApprovalPrivacyPolicy.plan(screenState: .unlocked, language: "en"),
            .detailedConfirmation
        )
        XCTAssertEqual(
            AgentApprovalPrivacyPolicy.plan(screenState: .unknown, language: "en"),
            .lockedReminder(
                title: "Ask Key has pending requests",
                body: "Unlock your Mac to review a pending request."
            )
        )
    }

    func testApprovalDetailsAreLoadedOnlyAfterExplicitlyUnlockedScreenState() {
        var loads = 0
        let load = {
            loads += 1
            return 42
        }

        switch AgentApprovalPrivacyPolicy.gatedRequest(screenState: .locked, load: load) {
        case .lockedReminder: break
        case .detailed: XCTFail("locked screen loaded request details")
        }
        switch AgentApprovalPrivacyPolicy.gatedRequest(screenState: .unknown, load: load) {
        case .lockedReminder: break
        case .detailed: XCTFail("unknown screen loaded request details")
        }
        XCTAssertEqual(loads, 0)

        switch AgentApprovalPrivacyPolicy.gatedRequest(screenState: .unlocked, load: load) {
        case .lockedReminder:
            XCTFail("unlocked screen did not load request")
        case .detailed(let request):
            XCTAssertEqual(request, 42)
        }
        XCTAssertEqual(loads, 1)
    }

    func testLockedReminderIsMarkedPostedOnlyAfterSuccessfulDelivery() {
        XCTAssertTrue(
            LockedApprovalReminderDeliveryPolicy.marksNotificationPosted(for: .delivered)
        )
        XCTAssertFalse(
            LockedApprovalReminderDeliveryPolicy.marksNotificationPosted(
                for: .authorizationUnavailable
            )
        )
        XCTAssertFalse(
            LockedApprovalReminderDeliveryPolicy.marksNotificationPosted(for: .deliveryFailed)
        )
    }

    func testGrokCleanupFailurePropagatesThroughConnectorAndUIState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyGrokConnectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let grok = root.appendingPathComponent("grok")
        try Data("""
        #!/bin/sh
        if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
          echo "--scope user"
          exit 0
        fi
        echo "[]"
        exit 0
        """.utf8).write(to: grok)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: grok.path)
        let grokHome = root.appendingPathComponent("grok-home", isDirectory: true)
        try FileManager.default.createDirectory(at: grokHome, withIntermediateDirectories: false)
        let isolatedHome = root.appendingPathComponent("isolated", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: false)
        let adapter = GrokCLIAdapter(
            grokHome: grokHome,
            isolatedHome: isolatedHome,
            helperExecutable: root.appendingPathComponent("helper"),
            grokExecutable: grok,
            backupDirectory: root.appendingPathComponent("backup", isDirectory: true),
            brokerSocketPath: root.appendingPathComponent("broker.sock").path,
            makeDiagnosticsProbe: {
                root.appendingPathComponent("diagnostics-probe", isDirectory: true)
            },
            removeDiagnosticsProbe: { _ in throw CocoaError(.fileWriteUnknown) }
        )

        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })
        let preview = await viewModel.loadAgentClientPreview {
            try AgentClientConnector.previewGrok(adapter)
        }
        XCTAssertNil(preview)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCodexPreviewFailurePropagatesThroughConnectorAndUIState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCodexPreviewTests-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not = [[\n".utf8).write(to: config)
        let adapter = CodexUserMCPAdapter(
            configURL: config,
            helperURL: root.appendingPathComponent("helper"),
            backupDirectory: root.appendingPathComponent("backup", isDirectory: true),
            brokerSocketPath: root.appendingPathComponent("broker.sock").path,
            command: CodexMCPCommand(
                status: { .supported(version: "0.50.0") },
                addAskKey: { _, _ in }
            )
        )
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })

        let preview = await viewModel.loadAgentClientPreview {
            try AgentClientConnector.previewCodex(adapter)
        }

        XCTAssertNil(preview)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCodexUnsafeConfigPreviewFailurePropagatesThroughConnectorAndUIState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCodexUnsafePreviewTests-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: root.appendingPathComponent("target"))
        let adapter = codexAdapter(root: root, config: config, status: .supported(version: "0.50.0"))
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })

        let preview = await viewModel.loadAgentClientPreview {
            try AgentClientConnector.previewCodex(adapter)
        }

        XCTAssertNil(preview)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCodexUnknownVersionPreviewFailurePropagatesThroughConnectorAndUIState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCodexVersionPreviewTests-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: config)
        let adapter = codexAdapter(root: root, config: config, status: .unknown(version: "future"))
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })

        let preview = await viewModel.loadAgentClientPreview {
            try AgentClientConnector.previewCodex(adapter)
        }

        XCTAssertNil(preview)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testAllCredentialSectionsExposeImportWithTheCorrectDestinationGroup() {
        XCTAssertEqual(CredentialWorkspaceSection.all.importDestinationGroup, nil)
        XCTAssertEqual(CredentialWorkspaceSection.ungrouped.importDestinationGroup, nil)
        XCTAssertEqual(CredentialWorkspaceSection.named("Work").importDestinationGroup, "Work")
        XCTAssertTrue(CredentialWorkspaceSection.all.showsCredentialImport)
        XCTAssertTrue(CredentialWorkspaceSection.ungrouped.showsCredentialImport)
        XCTAssertTrue(CredentialWorkspaceSection.named("Work").showsCredentialImport)
        XCTAssertFalse(CredentialWorkspaceSection.accessRecords.showsCredentialImport)
    }

    func testConnectionGateRejectsDuplicateAndStaleCompletions() throws {
        var gate = AgentConnectionGate()
        let first = try XCTUnwrap(gate.begin(.grok))
        XCTAssertNil(gate.begin(.grok))
        XCTAssertTrue(gate.isConnecting(.grok))
        XCTAssertTrue(gate.complete(.grok, generation: first))
        XCTAssertFalse(gate.complete(.grok, generation: first))
        let second = try XCTUnwrap(gate.begin(.grok))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(gate.complete(.grok, generation: first))
        XCTAssertTrue(gate.complete(.grok, generation: second))
    }

    func testConnectorSerializesConcurrentConnectionsForTheSameClient() {
        let probe = ConnectionConcurrencyProbe()
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                AgentClientConnector.performExclusive(client: .grok) {
                    probe.enter()
                    Thread.sleep(forTimeInterval: 0.05)
                    probe.leave()
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(probe.maximum, 1)
    }

    func testFailedConcurrentCursorConnectionDoesNotUndoSuccessfulConnection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCursorConcurrentTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let backup = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = Bundle(for: AgentClientConnectorTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("askkey")
        let socket = "/tmp/akcon-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8)).sock"
        let server = BrokerSocketServer(
            socketPath: socket,
            handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        )
        try server.start()
        defer { server.stop() }
        let successful = UnsafeSendableBox(CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: backup,
            helperURL: helper,
            brokerSocketPath: socket,
            signing: .development
        ))
        let failing = UnsafeSendableBox(CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: backup,
            helperURL: root.appendingPathComponent("missing-helper"),
            brokerSocketPath: socket
        ))
        let group = DispatchGroup()
        let results = ConnectionResults()
        group.enter()
        DispatchQueue.global().async {
            results.append(try? AgentClientConnector.connectCursorExclusively(successful.value))
            group.leave()
        }
        Thread.sleep(forTimeInterval: 0.02)
        group.enter()
        DispatchQueue.global().async {
            results.append(try? AgentClientConnector.connectCursorExclusively(failing.value))
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(results.values, [true, false])
        let config = home.appendingPathComponent(".cursor/mcp.json")
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains("askkey"))
    }

    func testBundleEditorNeverOffersTheLegacyGlobalEnvironmentVariable() {
        XCTAssertFalse(
            CredentialEditorPresentation.showsGlobalEnvironmentVariable(
                editingExisting: false,
                payloadKind: .text
            )
        )
        XCTAssertFalse(
            CredentialEditorPresentation.showsGlobalEnvironmentVariable(
                editingExisting: true,
                payloadKind: .bundle
            )
        )
        XCTAssertTrue(
            CredentialEditorPresentation.showsGlobalEnvironmentVariable(
                editingExisting: true,
                payloadKind: .text
            )
        )
    }

    func testBundleEditorRejectsTheWholePersistedBundleWhenAFileComponentIsInvalid() {
        let components = [
            ManagedCredentialComponent(name: "USERNAME", value: .text("agent")),
            ManagedCredentialComponent(name: "CERTIFICATE", value: .file(filename: "", bytes: Data("x".utf8)))
        ]

        XCTAssertThrowsError(try CredentialEditorComponentLoader.load(components))
    }

    func testBundleEditorRejectsHalfFilledOptionalComponents() {
        let complete = CredentialComponentDraft(name: "PRIMARY", text: "value")

        XCTAssertTrue(CredentialEditorComponentValidation.canSave([complete]))
        XCTAssertTrue(CredentialEditorComponentValidation.canSave([
            complete,
            CredentialComponentDraft(isOptional: true),
        ]))
        XCTAssertFalse(CredentialEditorComponentValidation.canSave([
            complete,
            CredentialComponentDraft(name: "SECONDARY", isOptional: true),
        ]))
        XCTAssertNil(CredentialEditorComponentValidation.inputs([
            complete,
            CredentialComponentDraft(name: "SECONDARY", isOptional: true),
        ]))
        XCTAssertFalse(CredentialEditorComponentValidation.canSave([
            complete,
            CredentialComponentDraft(text: "orphan-value", isOptional: true),
        ]))
    }

    func testAPITemplateCanSaveWithAnEmptyEndpoint() throws {
        var components = CredentialTemplate.api.components
        guard let keyIndex = components.firstIndex(where: { $0.name == "API_KEY" }) else {
            return XCTFail("API template must include API_KEY")
        }
        components[keyIndex].text = "secret-key"

        XCTAssertTrue(CredentialEditorComponentValidation.canSave(components))
        let inputs = try XCTUnwrap(CredentialEditorComponentValidation.inputs(components))
        XCTAssertEqual(inputs.map(\.name), ["API_KEY"])

        guard let endpointIndex = components.firstIndex(where: { $0.name == "API_ENDPOINT" }) else {
            return XCTFail("API template must include API_ENDPOINT")
        }
        components[endpointIndex].name = "CUSTOM_SECRET"
        XCTAssertFalse(CredentialEditorComponentValidation.canSave(components))
        XCTAssertNil(CredentialEditorComponentValidation.inputs(components))
    }

    func testCursorVerificationFailureRestoresOriginalConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCursorConnectorTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let config = home.appendingPathComponent(".cursor/mcp.json")
        let backup = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data(#"{"mcpServers":{"existing":{"command":"/usr/bin/true"}}}"#.utf8)
        try original.write(to: config)
        let adapter = CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: backup,
            helperURL: root.appendingPathComponent("missing-helper"),
            brokerSocketPath: root.appendingPathComponent("missing.sock").path
        )

        XCTAssertFalse(try AgentClientConnector.connectCursor(adapter))
        XCTAssertEqual(try Data(contentsOf: config), original)
    }

    func testCursorRollbackFailurePropagatesThroughConnectorAndUIState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCursorRollbackTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: root.appendingPathComponent("backups", isDirectory: true),
            helperURL: root.appendingPathComponent("missing-helper"),
            brokerSocketPath: root.appendingPathComponent("missing.sock").path,
            removeConfig: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })

        let connected = await viewModel.loadAgentClientConnection {
            try AgentClientConnector.connectCursor(adapter)
        }

        XCTAssertNil(connected)
        XCTAssertEqual(viewModel.errorMessage, CursorMCPError.rollbackFailed.localizedDescription)
    }

    func testCursorBackupCleanupFailurePropagatesThroughConnectorAndUIState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCursorCleanupTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = Bundle(for: AgentClientConnectorTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("askkey")
        let socket = "/tmp/akcc-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8)).sock"
        let server = BrokerSocketServer(
            socketPath: socket,
            handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        )
        try server.start()
        defer { server.stop() }
        let adapter = CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: root.appendingPathComponent("backups", isDirectory: true),
            helperURL: helper,
            brokerSocketPath: socket,
            signing: .development,
            removeBackupItem: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })

        let connected = await viewModel.loadAgentClientConnection {
            try AgentClientConnector.connectCursor(adapter)
        }

        XCTAssertNil(connected)
        XCTAssertEqual(
            viewModel.errorMessage,
            CursorMCPError.backupCleanupFailed.localizedDescription
        )
    }

    func testCursorPreviewDoesNotCreateLocksOrMutateBackups() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCursorPreviewTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let backup = root.appendingPathComponent("client-backups/cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: backup,
            helperURL: root.appendingPathComponent("missing-helper"),
            brokerSocketPath: root.appendingPathComponent("missing.sock").path
        )

        _ = try AgentClientConnector.previewCursor(adapter)

        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: backup.deletingLastPathComponent().appendingPathComponent(".cursor.lock").path
        ))
    }

    func testCodexConfigurationPresenceSurvivesUnavailableCLIAndRecognizesQuotedInlineForms() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyCodexPresence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.toml")
        let adapter = codexAdapter(root: root, config: config, status: .unknown(version: "future"))
        XCTAssertFalse(try adapter.hasConfiguration())
        for source in [
            "[mcp_servers.askkey]\ncommand = \"/missing/helper\"\nargs = [\"mcp\"]\n",
            "[\"mcp_servers\".'askkey']\ncommand = \"/missing/helper\"\n",
            "[mcp_servers]\n\"askkey\" = { command = \"/missing/helper\", args = [\"mcp\"] }\n",
            "[mcp_servers]\n'askkey' = { command = \"/missing/helper\" }\n",
            "mcp_servers = { askkey = { command = \"/missing/helper\", args = [\"mcp\"] } }\n",
            "\"mcp_servers\" = { other = { args = [\"one,two\"], env = { X = \"a,b\" } }, 'askkey' = { command = \"/missing/helper\" } }\n",
        ] {
            let bytes = Data(source.utf8)
            try bytes.write(to: config)
            let preview = try AgentClientConnector.previewCodex(adapter)
            XCTAssertTrue(preview.configurationPresent)
            XCTAssertFalse(preview.connected)
            XCTAssertEqual(try Data(contentsOf: config), bytes)
        }
        for source in [
            "mcp_servers = { other = { askkey = { command = \"/missing/helper\" } } }\n",
            "mcp_servers = { other = { command = \"x, askkey = y\", args = [\"mcp\"] } }\n",
            "mcp_servers = { \"askkey.other\" = { command = \"/missing/helper\" } }\n",
        ] {
            try Data(source.utf8).write(to: config)
            XCTAssertFalse(try adapter.hasConfiguration())
        }
        try Data("mcp_servers = { askkey = { command = \"unterminated\n".utf8).write(to: config)
        XCTAssertThrowsError(try adapter.hasConfiguration())
        try Data("[mcp_servers.askkey\n".utf8).write(to: config)
        XCTAssertThrowsError(try AgentClientConnector.previewCodex(adapter))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backup").path))
    }

    func testCursorConfigurationPresenceSurvivesMissingHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyCursorPresence-\(UUID().uuidString)")
        let config = root.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = CursorUserMCPAdapter(
            homeDirectory: root,
            backupDirectory: root.appendingPathComponent("backup"),
            helperURL: root.appendingPathComponent("missing-helper"),
            brokerSocketPath: root.appendingPathComponent("missing.sock").path
        )
        XCTAssertFalse(try AgentClientConnector.previewCursor(adapter).configurationPresent)
        let bytes = Data(#"{"mcpServers":{"askkey":{"command":"/missing/helper","args":["mcp"]}}}"#.utf8)
        try bytes.write(to: config)
        let preview = try AgentClientConnector.previewCursor(adapter)
        XCTAssertTrue(preview.configurationPresent)
        XCTAssertFalse(preview.connected)
        XCTAssertEqual(try Data(contentsOf: config), bytes)
        try Data("{".utf8).write(to: config)
        XCTAssertThrowsError(try AgentClientConnector.previewCursor(adapter))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backup").path))
    }

    func testGrokConfigurationPresenceSurvivesMissingCLIAndHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyGrokPresence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = GrokCLIAdapter(
            grokHome: root,
            isolatedHome: root.appendingPathComponent("isolated"),
            helperExecutable: root.appendingPathComponent("missing-helper"),
            grokExecutable: root.appendingPathComponent("missing-grok"),
            backupDirectory: root.appendingPathComponent("backup"),
            brokerSocketPath: root.appendingPathComponent("missing.sock").path
        )
        XCTAssertFalse(try adapter.hasConfiguration())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("isolated").path))
        XCTAssertFalse(try AgentClientConnector.previewGrok(adapter).configurationPresent)
        let bytes = Data("[mcp_servers.askkey]\ncommand = \"/missing/helper\"\nargs = [\"mcp\"]\n".utf8)
        try bytes.write(to: adapter.configURL)
        let preview = try AgentClientConnector.previewGrok(adapter)
        XCTAssertTrue(preview.configurationPresent)
        XCTAssertFalse(preview.connected)
        XCTAssertEqual(try Data(contentsOf: adapter.configURL), bytes)
        try Data("[mcp_servers.askkey\n".utf8).write(to: adapter.configURL)
        XCTAssertThrowsError(try AgentClientConnector.previewGrok(adapter))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backup").path))
    }

    private func codexAdapter(
        root: URL,
        config: URL,
        status: CodexMCPCLIStatus
    ) -> CodexUserMCPAdapter {
        CodexUserMCPAdapter(
            configURL: config,
            helperURL: root.appendingPathComponent("helper"),
            backupDirectory: root.appendingPathComponent("backup", isDirectory: true),
            brokerSocketPath: root.appendingPathComponent("broker.sock").path,
            command: CodexMCPCommand(status: { status }, addAskKey: { _, _ in })
        )
    }

}

private final class ConnectionAttemptProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var count: Int { lock.withLock { storage } }
    func record() { lock.withLock { storage += 1 } }
}

private final class ConnectionConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var highest = 0
    var maximum: Int { lock.withLock { highest } }

    func enter() {
        lock.withLock {
            active += 1
            highest = max(highest, active)
        }
    }

    func leave() { lock.withLock { active -= 1 } }
}

private final class ConnectionResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []
    var values: [Bool] { lock.withLock { storage } }
    func append(_ value: Bool?) { if let value { lock.withLock { storage.append(value) } } }
}

private struct UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

extension AgentClientConnectorTests {
}
