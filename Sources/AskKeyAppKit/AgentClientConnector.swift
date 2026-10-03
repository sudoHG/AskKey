import Foundation
import AskKeyBroker
import AskKeyCore
#if DEBUG
import AppKit
import Darwin
#endif

enum AgentClient: String, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case cursor = "Cursor"
    case grok = "Grok CLI"

    var id: String { rawValue }
    var proofID: String {
        switch self {
        case .codex: return "codex"
        case .cursor: return "cursor"
        case .grok: return "grok"
        }
    }
    var isAutomatic: Bool { true }

    var connectionPreviewSummary: String {
        if self == .codex {
            return appLocalized("Ask Key will back up Codex's user-level configuration, add Ask Key and credential discovery before SSH, then verify both. Only this Ask Key hook will be trusted.")
        }
        return appLocalizedFormat("Ask Key will back up %@'s user settings, add Ask Key and credential discovery before SSH, then verify the connection and configuration.", rawValue)
    }

    var connectionSuccessMessage: String {
        if self == .codex {
            return appLocalized("MCP is connected and credential discovery before SSH is enabled. Start a new Codex task to use it.")
        }
        return appLocalizedFormat("Ask Key was added to %@ and the connection was verified.", rawValue)
    }
}

struct AgentClientPreview: Sendable {
    let summary: String
    let connected: Bool
    var configurationPresent: Bool = false
    var discovery: CredentialDiscoveryReadiness? = nil
}

#if DEBUG
struct DebugClientE2ERequest: Equatable, Sendable {
    let client: AgentClient
    let home: URL
    let output: URL

    static func parse(
        environment: [String: String],
        actualHome: URL
    ) -> Self? {
        let client: AgentClient? = switch environment["ASKKEY_CLIENT_E2E"]?.lowercased() {
        case "codex": .codex
        case "cursor": .cursor
        case "grok": .grok
        default: nil
        }
        guard let client,
              let homePath = environment["ASKKEY_CLIENT_E2E_HOME"],
              let outputPath = environment["ASKKEY_CLIENT_E2E_OUTPUT"] else { return nil }
        let home = URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
        let output = URL(fileURLWithPath: outputPath).standardizedFileURL
        var homeInfo = stat()
        guard home.path.withCString({ lstat($0, &homeInfo) }) == 0,
              homeInfo.st_mode & S_IFMT == S_IFDIR,
              homeInfo.st_uid == geteuid(),
              homeInfo.st_mode & 0o077 == 0 else { return nil }
        let resolvedHome = home.resolvingSymlinksInPath().standardizedFileURL
        let resolvedOutput = output.resolvingSymlinksInPath().standardizedFileURL
        let actual = actualHome.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedHome.path != actual,
              resolvedHome.path != "/",
              resolvedOutput.deletingLastPathComponent() == resolvedHome else { return nil }
        var outputInfo = stat()
        if resolvedOutput.path.withCString({ lstat($0, &outputInfo) }) == 0 {
            guard outputInfo.st_mode & S_IFMT == S_IFREG,
                  outputInfo.st_uid == geteuid() else { return nil }
        } else if errno != ENOENT {
            return nil
        }
        return Self(
            client: client,
            home: resolvedHome,
            output: resolvedOutput
        )
    }
}

struct DebugClientE2EResult: Codable {
    let client: String
    let previewConnected: Bool
    let connected: Bool
    let rollback: String
    let error: String?
    var configured: Bool = false

    static func completed(client: AgentClient, connected: Bool, previewConnected: Bool = false) -> Self {
        Self(
            client: client.rawValue,
            previewConnected: previewConnected,
            connected: connected,
            rollback: connected ? "not_needed" : "completed",
            error: connected ? nil : AgentClientErrorCopy.message(for: client),
            configured: connected
        )
    }

    static func failed(client: AgentClient, error: Error) -> Self {
        Self(
            client: client.rawValue,
            previewConnected: false,
            connected: false,
            rollback: "adapter_managed",
            error: AgentClientErrorCopy.message(for: client, error: error)
        )
    }
}

enum DebugClientE2ERunner {
    @MainActor
    static func startIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ASKKEY_CLIENT_E2E"] != nil else { return false }
        guard let request = DebugClientE2ERequest.parse(
            environment: environment,
            actualHome: FileManager.default.homeDirectoryForCurrentUser
        ) else {
            fail("Ask Key client E2E request is invalid: use codex, cursor, or grok with an owner-only 0700 home and a direct result file inside it")
        }
        Task.detached {
            let connector = AgentClientConnector(
                home: request.home,
                supportDirectory: request.home.appendingPathComponent("support", isDirectory: true)
            )
            let result: DebugClientE2EResult
            do {
                let preview = try connector.preview(request.client)
                result = .completed(
                    client: request.client,
                    connected: try connector.connect(request.client),
                    previewConnected: preview.connected
                )
            } catch {
                result = .failed(client: request.client, error: error)
            }
            do {
                try FileManager.default.createDirectory(
                    at: request.home,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try JSONEncoder().encode(result).write(to: request.output, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: request.output.path
                )
            } catch {
                fail("Ask Key client E2E could not write its result: \(error.localizedDescription)")
            }
            await MainActor.run { NSApp.terminate(nil) }
        }
        return true
    }

    private static func fail(_ message: String) -> Never {
        NSLog("%@", message)
        fputs(message + "\n", stderr)
        fflush(stderr)
        // This explicit Debug harness is a command boundary; failure must be non-zero.
        Darwin.exit(EXIT_FAILURE)
    }
}
#endif

enum AgentClientFailureKind {
    case configuration
    case unsupported
    case helper
    case broker
    case rollback
    case verification
}

enum OfficialInstallCopy {
    static func message(for error: OfficialInstallTopologyError) -> String {
        switch error {
        case .unavailable(let decision):
            return message(for: decision)
        }
    }

    static func message(for decision: OfficialInstallDecision) -> String {
        switch decision {
        case .accepted, .developmentAccepted:
            return ""
        case .relocatedOrRenamed:
            return appLocalized("Ask Key must stay at /Applications/Ask Key.app. Reinstall the official package, then open that copy.")
        case .helperMismatch:
            return appLocalized("This Ask Key helper does not match the official app. Reinstall the official package, then try again.")
        }
    }
}

enum AgentClientErrorCopy {
    static func message(for client: AgentClient, error: Error? = nil) -> String {
        if let error = error as? OfficialInstallTopologyError {
            return OfficialInstallCopy.message(for: error)
        }
        let kind = classify(error)
        let name = client.rawValue
        switch kind {
        case .configuration:
            return appLocalizedFormat("The %@ user configuration cannot be updated safely. Fix that configuration, then try again.", name)
        case .unsupported:
            if client == .codex {
                return appLocalized("Ask Key has not verified automatic setup for this Codex version. Contact support to confirm compatibility, then try again.")
            }
            return appLocalizedFormat("This version of %@ does not support automatic setup. Update %@, then try again.", name, name)
        case .helper:
            return appLocalized("The Ask Key helper signature or version does not match. Reinstall Ask Key, then try again.")
        case .broker:
            return appLocalized("Ask Key is not running. Open Ask Key, then try again.")
        case .rollback:
            return appLocalizedFormat("Ask Key could not restore the original %@ configuration. Stop retrying and contact support.", name)
        case .verification:
            return appLocalizedFormat("%@ did not complete the connection check. Restart %@, then try again.", name, name)
        }
    }

    private static func classify(_ error: Error?) -> AgentClientFailureKind {
        if let error = error as? CodexUserMCPError {
            switch error {
            case .unsafeConfigFile, .illegalConfig: return .configuration
            case .unknownCodexVersion: return .unsupported
            case .rollbackFailed: return .rollback
            case .connectionFailed(let reason):
                if reason == "helper" { return .helper }
            if reason == "broker" { return .broker }
            if reason == "version" { return .helper }
                return .verification
            }
        }
        if let error = error as? CursorMCPError {
            switch error {
            case .unsafeFile, .invalidJSON, .replaceFailed, .readbackFailed:
                return .configuration
            case .rollbackFailed: return .rollback
            case .backupCleanupFailed: return .configuration
            }
        }
        if let error = error as? GrokCLIAdapterError {
            switch error {
            case .unsafeConfig, .invalidConfig: return .configuration
            case .unsupportedClient: return .unsupported
            case .rollbackFailed: return .rollback
            case .verificationFailed(let reason):
                if reason.contains("helper") { return .helper }
                if reason.contains("broker") { return .broker }
                return .verification
            case .backupCleanupFailed, .diagnosticsCleanupFailed:
                return .configuration
            }
        }
        return .verification
    }
}

struct AgentConnectionGate {
    private var generations: [AgentClient: UUID] = [:]

    mutating func begin(_ client: AgentClient) -> UUID? {
        guard generations[client] == nil else { return nil }
        let generation = UUID()
        generations[client] = generation
        return generation
    }

    mutating func complete(_ client: AgentClient, generation: UUID) -> Bool {
        guard generations[client] == generation else { return false }
        generations.removeValue(forKey: client)
        return true
    }

    func isConnecting(_ client: AgentClient) -> Bool { generations[client] != nil }
}

struct AgentClientConnector: Sendable {
    private static let codexMutationLock = NSLock()
    private static let cursorMutationLock = NSLock()
    private static let grokMutationLock = NSLock()
    private let home: URL
    private let installationHome: URL
    private let supportDirectoryOverride: URL?
#if DEBUG
    private let helperURLOverride: URL?
#endif

    init(
        home: URL? = nil,
        installationHome: URL? = nil,
        supportDirectory: URL? = nil,
        helperURL: URL? = nil
    ) {
        self.home = home ?? Self.defaultClientHome
        self.installationHome = installationHome ?? home ?? FileManager.default.homeDirectoryForCurrentUser
        self.supportDirectoryOverride = supportDirectory
#if DEBUG
        self.helperURLOverride = helperURL
#else
        _ = helperURL
#endif
    }

    private static var defaultClientHome: URL {
#if DEBUG
        // A scoped test App must not silently point its ordinary Connect buttons
        // at the user's real client configuration. Explicit injected homes still
        // support adapter tests and the separate command harness.
        if let root = VaultConfiguration.debugRunDirectory {
            return root.appendingPathComponent("client-home", isDirectory: true)
        }
#endif
        return FileManager.default.homeDirectoryForCurrentUser
    }

    func preview(_ client: AgentClient) throws -> AgentClientPreview {
        switch client {
        case .codex:
            let report = try check(.codex)
            return AgentClientPreview(
                summary: AgentClient.codex.connectionPreviewSummary,
                connected: report.outcome == .verifiedConnected,
                configurationPresent: try codexAdapter().hasConfiguration()
            )
        case .cursor:
            let context = try commandDiscoveryContext(for: .cursor)
            return try Self.previewCursor(cursorAdapter(), context: context)
        case .grok:
            let context = try commandDiscoveryContext(for: .grok)
            return try Self.previewGrok(grokAdapter(), context: context)
        }
    }

    func connect(_ client: AgentClient) throws -> Bool {
        switch client {
        case .codex:
            let report = try check(.codex)
            if report.outcome == .verifiedConnected { return true }
            guard let plan = report.plan, report.failure == nil else {
                throw report.failure ?? AgentOnboardingFailure.verificationFailed
            }
            let result = try apply(.codex, plan: plan)
            if let failure = result.failure { throw failure }
            return result.outcome == .verifiedConnected
        case .cursor:
            let report = try check(.cursor)
            if report.outcome == .verifiedConnected { return true }
            guard let plan = report.plan, report.failure == nil else {
                throw report.failure ?? AgentOnboardingFailure.verificationFailed
            }
            let result = try apply(.cursor, plan: plan)
            if let failure = result.failure { throw failure }
            return result.outcome == .verifiedConnected
        case .grok:
            let report = try check(.grok)
            if report.outcome == .verifiedConnected { return true }
            guard let plan = report.plan, report.failure == nil else {
                throw report.failure ?? AgentOnboardingFailure.verificationFailed
            }
            let result = try apply(.grok, plan: plan)
            if let failure = result.failure { throw failure }
            return result.outcome == .verifiedConnected
        }
    }

    static func connectCursorExclusively(_ adapter: CursorUserMCPAdapter) throws -> Bool {
        try performExclusive(client: .cursor) { try connectCursor(adapter) }
    }

    static func performExclusive<T>(client: AgentClient, _ body: () throws -> T) rethrows -> T {
        let lock: NSLock
        switch client {
        case .codex: lock = codexMutationLock
        case .cursor: lock = cursorMutationLock
        case .grok: lock = grokMutationLock
        }
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    static func connectCursor(_ adapter: CursorUserMCPAdapter) throws -> Bool {
        _ = try adapter.apply()
        guard try adapter.verify().connected else {
            try adapter.rollback()
            return false
        }
        return true
    }

    static func previewCodex(_ adapter: CodexUserMCPAdapter) throws -> AgentClientPreview {
        let configurationPresent = try adapter.hasConfiguration()
        if !configurationPresent { _ = try adapter.preview() }
        return AgentClientPreview(
            summary: AgentClient.codex.connectionPreviewSummary,
            connected: adapter.status() == .connected,
            configurationPresent: configurationPresent
        )
    }

    static func previewCursor(_ adapter: CursorUserMCPAdapter) throws -> AgentClientPreview {
        let configurationPresent = try adapter.hasConfiguration()
        _ = try adapter.preview()
        return AgentClientPreview(
            summary: AgentClient.cursor.connectionPreviewSummary,
            connected: try adapter.status().connected,
            configurationPresent: configurationPresent
        )
    }

    static func previewCursor(
        _ adapter: CursorUserMCPAdapter,
        context: CommandDiscoverySetupContext
    ) throws -> AgentClientPreview {
        try context.verifyHelper()
        let hookPlan = try context.hook.preview()
        let preview = try previewCursor(adapter)
        return AgentClientPreview(
            summary: preview.summary,
            connected: preview.connected && !hookPlan.changed,
            configurationPresent: preview.configurationPresent,
            discovery: CommandHookOnboardingSetup.readiness(for: hookPlan)
        )
    }

    static func previewGrok(_ adapter: GrokCLIAdapter) throws -> AgentClientPreview {
        let configurationPresent = try adapter.hasConfiguration()
        let status = try adapter.status()
        _ = try adapter.preview()
        return AgentClientPreview(
            summary: AgentClient.grok.connectionPreviewSummary,
            connected: status.connected,
            configurationPresent: configurationPresent
        )
    }

    static func previewGrok(
        _ adapter: GrokCLIAdapter,
        context: CommandDiscoverySetupContext
    ) throws -> AgentClientPreview {
        try context.verifyHelper()
        let hookPlan = try context.hook.preview()
        let preview = try previewGrok(adapter)
        return AgentClientPreview(
            summary: preview.summary,
            connected: preview.connected && !hookPlan.changed,
            configurationPresent: preview.configurationPresent,
            discovery: CommandHookOnboardingSetup.readiness(for: hookPlan)
        )
    }

    var supportDirectory: URL {
        supportDirectoryOverride
            ?? VaultConfiguration.daemonSocketURL.deletingLastPathComponent()
    }

    private func resolvedHelperURL() throws -> URL {
#if DEBUG
        if let helperURLOverride {
            return helperURLOverride
        }
#endif
        return try OfficialInstallTopology.resolvedHelperURL(
            bundleURL: Bundle.main.bundleURL,
            isDevelopmentBuild: VaultConfiguration.isDevelopmentBuild
        )
    }

    func commandDiscoveryContext(for client: AgentClient) throws -> CommandDiscoverySetupContext {
        let discoveryClient: CommandDiscoveryClient
        switch client {
        case .cursor: discoveryClient = .cursor
        case .grok: discoveryClient = .grok
        default: throw AgentOnboardingFailure.unsupportedVersion
        }
        let helper = try resolvedHelperURL()
        let workingDirectory = home
        let hook = try discoveryClient.configuration(
            home: home,
            helper: helper,
            backupDirectory: supportDirectory.appendingPathComponent(
                "client-backups/\(client.proofID)-discovery",
                isDirectory: true
            )
        )
        return CommandDiscoverySetupContext(
            client: discoveryClient,
            helper: helper,
            hook: hook,
            verifyHelper: {
                try discoveryClient.verifyHelper(helper, workingDirectory: workingDirectory)
            }
        )
    }

    private var isolatedSigning: CodexHelperSigning {
#if DEBUG
        helperURLOverride == nil ? .executable : .development
#else
        .executable
#endif
    }

    var codexExecutable: URL {
        let desktop = home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            ? ["/Applications/ChatGPT.app/Contents/Resources/codex"] : []
        return firstExecutable(desktop + [
            home.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ])
    }

    func codexDiscoveryConfiguration() -> CodexDiscoveryHookConfiguration {
        CodexDiscoveryHookConfiguration(
            hooksURL: home.appendingPathComponent(".codex/hooks.json"),
            backupDirectory: supportDirectory.appendingPathComponent("client-backups/codex-discovery")
        )
    }

    func codexNativeHooks() -> CodexNativeHookClient {
        CodexNativeHookClient(executable: codexExecutable, userHome: home)
    }

    func codexAdapter(useNativeConfiguration: Bool = false) throws -> CodexUserMCPAdapter {
        let helperURL = try resolvedHelperURL()
        return CodexUserMCPAdapter(
            configURL: CodexUserMCP.userConfigURL(home: home),
            helperURL: helperURL,
            backupDirectory: CodexUserMCP.managedBackupDirectory(applicationSupport: supportDirectory),
            brokerSocketPath: BrokerConfiguration.socketURL.path,
            // Native onboarding validates app-server capability and authority
            // before using the adapter's existing direct TOML transaction.
            command: useNativeConfiguration ? .missing : ProcessCodexMCPCommand.make(executable: codexExecutable),
            signing: isolatedSigning,
            requiresCredentialDiscovery: useNativeConfiguration
        )
    }

    func cursorAdapter() throws -> CursorUserMCPAdapter {
        CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: supportDirectory
                .appendingPathComponent("client-backups/cursor", isDirectory: true),
            helperURL: try resolvedHelperURL(),
            brokerSocketPath: BrokerConfiguration.socketURL.path,
            signing: isolatedSigning
        )
    }

    func grokAdapter() throws -> GrokCLIAdapter {
        GrokCLIAdapter(
            grokHome: home.appendingPathComponent(".grok", isDirectory: true),
            isolatedHome: supportDirectory.appendingPathComponent("grok-home", isDirectory: true),
            helperExecutable: try resolvedHelperURL(),
            grokExecutable: firstExecutable([
                home.appendingPathComponent(".local/bin/grok").path,
                "/opt/homebrew/bin/grok",
                "/usr/local/bin/grok",
            ]),
            backupDirectory: supportDirectory
                .appendingPathComponent("client-backups/grok", isDirectory: true),
            brokerSocketPath: BrokerConfiguration.socketURL.path,
            signing: isolatedSigning
        )
    }

    private func firstExecutable(_ paths: [String]) -> URL {
        paths.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
            ?? paths.first.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: "/nonexistent")
    }

}

@MainActor
extension VaultViewModel {
    func loadAgentClientPreview(
        _ client: AgentClient,
        load: @escaping @Sendable () throws -> AgentClientPreview
    ) async -> AgentClientPreview? {
        do {
            return try await Task.detached(operation: load).value
        } catch {
            return nil
        }
    }

    func loadAgentClientPreview(
        _ load: @escaping @Sendable () throws -> AgentClientPreview
    ) async -> AgentClientPreview? {
        do {
            return try await Task.detached(operation: load).value
        } catch {
            return nil
        }
    }

    func loadAgentClientConnection(
        _ connect: @escaping @Sendable () throws -> Bool
    ) async -> Bool? {
        do {
            return try await Task.detached(operation: connect).value
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func connectAgentClient(
        _ connect: @escaping @Sendable () throws -> Bool
    ) async -> Bool? {
        guard !isLocked, hasManagementSession else {
            errorMessage = appLocalized(
                "Credential management requires confirmation before it can continue."
            )
            return nil
        }
        renewManagementSession()
        return await loadAgentClientConnection(connect)
    }

    func connectAgentClient(
        _ client: AgentClient,
        connect: @escaping @Sendable () throws -> Bool
    ) async -> Bool? {
        guard !isLocked, hasManagementSession else {
            errorMessage = appLocalized(
                "Credential management requires confirmation before it can continue."
            )
            return nil
        }
        renewManagementSession()
        do {
            guard try await Task.detached(operation: connect).value else {
                errorMessage = AgentClientErrorCopy.message(for: client)
                return nil
            }
            return true
        } catch {
            errorMessage = AgentClientErrorCopy.message(for: client, error: error)
            return nil
        }
    }
}
