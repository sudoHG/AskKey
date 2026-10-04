import AppKit
import AskKeyAppKit
import AskKeyBroker
import AskKeyVault
import Foundation
import Darwin

/// Linked only by the separate optimized E2E executable. UI actions are never
/// synthesized here: the independent XCTest runner clicks the actual controls.
@MainActor
package enum E2EAppRuntime {
    package static func configuration() -> AppRuntimeConfiguration {
        prepareIsolation()
        Vault.configureShared(VaultE2EFixture.makeVault())
        if ProcessInfo.processInfo.environment["ASKKEY_CLIENT_E2E"] != nil {
            return AppRuntimeConfiguration(startClient: DebugClientE2ERunner.startIfRequested)
        }
        return AppRuntimeConfiguration(
            makeViewModel: makeViewModel,
            prepareServices: configureE2EAuthentication,
            didStart: startScenario,
            willStop: stop
        )
    }

    private static func configureE2EAuthentication() {
        Vault.shared.approvalRequests.configureAuthentication { _ in true }
    }
    static func prepareIsolation() {
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "com.sudohg.askkey.app.e2e",
              Bundle.main.object(forInfoDictionaryKey: "AskKeyE2ETesting") as? Bool == true,
              let rootPath = environment["ASKKEY_E2E_ROOT"],
              let runtimePath = environment["ASKKEY_DEBUG_RUN_DIRECTORY"],
              runtimePath == environment["ASKKEY_E2E_RUN_DIRECTORY"],
              let controlPath = environment["ASKKEY_E2E_CONTROL_DIRECTORY"] else {
            fatalError("E2E requires explicit runtime and control directories")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let runtime = URL(fileURLWithPath: runtimePath, isDirectory: true)
        let control = URL(fileURLWithPath: controlPath, isDirectory: true)
        var stage = "validate requested paths"
        var rootValidated = false
        do {
            guard root.deletingLastPathComponent().path == "/private/tmp",
                  root.lastPathComponent.hasPrefix("ak-e2e-"),
                  runtime.deletingLastPathComponent().path == root.path,
                  runtime.lastPathComponent.range(of: "^[a-f0-9]{16}$", options: .regularExpression) != nil,
                  runtime.appendingPathComponent("daemon.sock").path.utf8.count < 104 else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            stage = "validate private runtime root"
            try validatePrivateDirectory(root)
            rootValidated = true
            stage = "validate runner control directory"
            try validatePrivateDirectory(control)
            stage = "create case runtime directory"
            if !FileManager.default.fileExists(atPath: runtime.path) {
                try FileManager.default.createDirectory(
                    at: runtime, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            stage = "validate case runtime directory"
            try validatePrivateDirectory(runtime)
            stage = "resolve production Debug run directory"
            guard try DebugRunDirectory.resolve()?.path == runtime.path else {
                throw CocoaError(.fileReadNoPermission)
            }
        } catch {
            let detail = "\(stage): \(String(reflecting: error))"
            let report = ["stage": stage, "error": detail]
            if rootValidated,
               let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("isolation-failure-\(UUID().uuidString).json"), options: .atomic)
            }
            fatalError("E2E isolation setup failed at \(detail)")
        }
    }

    private static func validatePrivateDirectory(_ directory: URL) throws {
        guard directory.pathComponents.count > 1 else {
            throw isolationError(directory.path, "The filesystem root cannot be an E2E private directory")
        }
        // Foundation may fold canonical /private/tmp back to /tmp on macOS.
        // Match production's filesystem check instead: inspect every component
        // without following links, then require private ownership of the leaf.
        var candidate = URL(fileURLWithPath: "/", isDirectory: true)
        for component in directory.pathComponents.dropFirst() {
            guard component != "." && component != ".." else {
                throw isolationError(directory.path, "Relative path component")
            }
            candidate.appendPathComponent(component, isDirectory: true)
            var info = stat()
            guard candidate.path.withCString({ lstat($0, &info) }) == 0 else {
                throw isolationError(candidate.path, "lstat failed with errno \(errno)")
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw isolationError(candidate.path, "Component is not a directory or is a symbolic link")
            }
            if candidate.path == directory.path {
                guard info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
                    throw isolationError(candidate.path, "Expected owner \(geteuid()) mode 0700; got owner \(info.st_uid) mode \(String(info.st_mode & 0o777, radix: 8))")
                }
            }
        }
    }

    private static func isolationError(_ path: String, _ message: String) -> NSError {
        NSError(domain: "AskKeyE2EIsolation", code: 1,
                userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: message])
    }

    static var controlDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ASKKEY_E2E_CONTROL_DIRECTORY"]!, isDirectory: true)
    }

    static var runDirectory: URL {
        guard Bundle.main.bundleIdentifier == "com.sudohg.askkey.app.e2e",
              Bundle.main.object(forInfoDictionaryKey: "AskKeyE2ETesting") as? Bool == true,
              let directory = VaultConfiguration.debugRunDirectory,
              ProcessInfo.processInfo.environment["ASKKEY_E2E_RUN_DIRECTORY"] == directory.path else {
            fatalError("E2E requires a marked bundle and an explicit isolated run directory")
        }
        return directory
    }

    static var scenario: String {
        ProcessInfo.processInfo.environment["ASKKEY_E2E_SCENARIO"] ?? "connected"
    }

    static func makeViewModel() -> VaultViewModel {
        let directory = runDirectory
        let selectedScenario = scenario
        let operations = AgentOnboardingRuntime.boundOperations(
            runCheck: { client in
                if selectedScenario == "failure" { throw AgentOnboardingFailure.verificationFailed }
                if selectedScenario == "cancel" {
                    try E2EProcessFixture.runSlowCommand(in: directory)
                }
                if selectedScenario == "discovery-missing", client == .codex {
                    return AgentCheckReport(
                        outcome: .configuredUnverified, targetSummary: "Codex", plan: nil,
                        failure: .discoverySetupFailed, discovery: .missing
                    )
                }
                if selectedScenario == "discovery-missing-local",
                   client == .cursor || client == .grok {
                    return AgentCheckReport(
                        outcome: .verifiedConnected, targetSummary: client.rawValue, plan: nil,
                        failure: nil, discovery: .missing
                    )
                }
                let discovery: CredentialDiscoveryReadiness? = switch client {
                case .codex: .enabled
                case .claudeCode, .cursor, .grok: .configured
                }
                return AgentCheckReport(
                    outcome: .verifiedConnected,
                    targetSummary: client.rawValue, plan: nil, failure: nil,
                    discovery: discovery
                )
            },
            runApply: { _, _ in throw AgentOnboardingFailure.planChanged },
            authenticate: { .confirmed }
        )
        let model = VaultViewModel.configured(
            languageMode: ProcessInfo.processInfo.environment["ASKKEY_E2E_LANGUAGE"] ?? "zh-Hans",
            appearanceMode: "light", completedOnboarding: true,
            readApprovalAuthenticationEnabled: true,
            unlockVault: {}, authenticateDeviceOwner: { _ in .allow },
            loginItemIsEnabled: { false }, setLoginItemEnabled: { _ in },
            onboardingOperations: operations
        )
        model.isLocked = true
        model.hasManagementSession = false
        model.showsLockedWorkbench = true
        return model
    }

    private static var driver: E2EBrokerScenario?

    static func startScenario() {
        driver = E2EBrokerScenario(directory: runDirectory, control: controlDirectory, scenario: scenario)
        driver?.start()
    }

    static func stop() { driver?.stop() }
}
