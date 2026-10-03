import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker
import CryptoKit

public struct GrokCLIConnectResult: Equatable, Sendable {
    public var connected: Bool
    public var reason: String
    public var diff: String
    public var listJSON: String
    public var doctorJSON: String
    public var helperVersion: String
}

public enum GrokCLIAdapterError: Error, Equatable, LocalizedError {
    case unsafeConfig
    case invalidConfig
    case unsupportedClient
    case verificationFailed(String)
    case rollbackFailed
    case backupCleanupFailed
    case diagnosticsCleanupFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeConfig:
            return "The Grok CLI config is not a regular user-level file."
        case .invalidConfig:
            return "The Grok CLI config is not valid TOML."
        case .unsupportedClient:
            return "This Grok CLI build does not support user-scoped MCP management."
        case .verificationFailed(let reason):
            return "Grok CLI connection verification failed (\(reason))."
        case .rollbackFailed:
            return "Ask Key could not restore the previous Grok CLI config."
        case .backupCleanupFailed:
            return "Ask Key connected Grok CLI but could not delete the rollback backup."
        case .diagnosticsCleanupFailed:
            return "Ask Key could not remove the temporary Grok configuration probe."
        }
    }
}

public struct GrokCLIAdapter: Sendable {
    public var grokHome: URL
    public var isolatedHome: URL
    public var helperExecutable: URL
    public var grokExecutable: URL
    public var backupDirectory: URL
    public var brokerSocketPath: String
    public var signing: CodexHelperSigning
    public var helperEnvironment: [String: String]
    public var serverName: String
    public var commandTimeout: TimeInterval = 12
    public var terminationGrace: TimeInterval = 1
    var capturedOutputLimit = BrokerLimits.maximumResponseBytes
    public var removeBackupItem: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    public var makeDiagnosticsProbe: @Sendable () -> URL
    public var removeDiagnosticsProbe: @Sendable (URL) throws -> Void
    public var beforeRollback: @Sendable () throws -> Void = {}
    public var afterReplacementWrite: @Sendable () throws -> Void = {}
    public var afterOfficialPreflight: @Sendable () throws -> Void = {}
    // Test-only observation seam; it cannot alter the write or replacement path.
    var observeAtomicWriteTemporary: @Sendable (URL) -> Void = { _ in }
    let outputCapture = OutputCapture()
    var lastCapturedOutputBytes: Int { outputCapture.bytes }

    public init(
        grokHome: URL,
        isolatedHome: URL,
        helperExecutable: URL,
        grokExecutable: URL,
        backupDirectory: URL,
        brokerSocketPath: String,
        signing: CodexHelperSigning = .executable,
        helperEnvironment: [String: String] = [:],
        serverName: String = "askkey",
        makeDiagnosticsProbe: @escaping @Sendable () -> URL = {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("AskKey-Grok-Probe-\(UUID().uuidString)", isDirectory: true)
        },
        removeDiagnosticsProbe: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) {
        self.grokHome = grokHome
        self.isolatedHome = isolatedHome
        self.helperExecutable = helperExecutable
        self.grokExecutable = grokExecutable
        self.backupDirectory = backupDirectory
        self.brokerSocketPath = brokerSocketPath
        self.signing = signing
        self.helperEnvironment = helperEnvironment
        self.serverName = serverName
        self.makeDiagnosticsProbe = makeDiagnosticsProbe
        self.removeDiagnosticsProbe = removeDiagnosticsProbe
    }

    public var configURL: URL { grokHome.appendingPathComponent("config.toml") }

    public func connect() throws -> GrokCLIConnectResult {
        try prepareIsolatedHome()
        try inspectConfigFile()
        let original = try readOriginal()
        if let text = original.text {
            try validateUserTOML(text)
        }
        try writeBackup(original)
        let result: GrokCLIConnectResult
        var appliedDigest: Data?
        do {
            try applyStdioConfig(
                originalText: original.text,
                appliedDigest: &appliedDigest
            )
            let verified = try verify(before: original.text ?? "")
            guard verified.connected else {
                throw GrokCLIAdapterError.verificationFailed(verified.reason)
            }
            result = verified
        } catch {
            if appliedDigest != nil {
                try beforeRollback()
                try restoreBackup(original, expectedDigest: appliedDigest)
            } else {
                try clearBackup()
            }
            if error is GrokCLIAdapterError { throw error }
            throw GrokCLIAdapterError.verificationFailed(error.localizedDescription)
        }
        try clearBackup()
        return result
    }

    public func status() throws -> GrokCLIConnectResult {
        try prepareIsolatedHome()
        try inspectConfigFile()
        let original = try readOriginal()
        if let text = original.text {
            try validateUserTOML(text)
            if GrokUserTOML.askKeyTransport(in: text) == .remote {
                return GrokCLIConnectResult(
                    connected: false,
                    reason: "remote_connector",
                    diff: "",
                    listJSON: "",
                    doctorJSON: "",
                    helperVersion: ""
                )
            }
        }
        return try verify(before: original.text ?? "")
    }

    /// Does not invoke Grok, create a diagnostics home, or write configuration.
    public func hasConfiguration() throws -> Bool {
        try inspectConfigFile()
        let text = try readOriginal().text ?? ""
        _ = try GrokUserTOML.parse(text)
        do {
            return try CodexAskKeyTOML.hasServer(in: text, named: serverName)
        } catch {
            throw GrokCLIAdapterError.invalidConfig
        }
    }

    public func preview() throws -> String {
        try prepareIsolatedHome()
        try inspectConfigFile()
        let original = try readOriginal().text ?? ""
        try validateUserTOML(original)
        let desired = try GrokUserTOML.upsertStdio(
            in: original,
            serverName: serverName,
            command: helperExecutable.path,
            args: ["mcp"],
            env: helperEnvironment
        )
        return GrokUserTOML.redactedDiff(before: original, after: desired)
    }

    func grokTOMLDiagnostics(
        _ text: String,
        probe: URL,
        removeProbe: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws -> String {
        let result = probe.path.withCString { mkdir($0, S_IRWXU) }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let diagnostics: Result<String, Error>
        do {
            let config = probe.appendingPathComponent("config.toml")
            try Data(text.utf8).write(to: config, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: config.path
            )
            let output = try runGrok(["mcp", "list", "--json"], grokHomeOverride: probe)
            diagnostics = .success(String(decoding: output.stdout + output.stderr, as: UTF8.self))
        } catch {
            diagnostics = .failure(error)
        }
        do {
            try removeProbe(probe)
        } catch {
            throw GrokCLIAdapterError.diagnosticsCleanupFailed
        }
        return try diagnostics.get()
    }
}

private struct OriginalConfig {
    var data: Data?
    var text: String?
    var mode: Int16?
}

private extension GrokCLIAdapter {
    var backupDataURL: URL { backupDirectory.appendingPathComponent("grok-cli.config.toml") }
    var backupStateURL: URL { backupDirectory.appendingPathComponent("grok-cli.state") }

    func prepareIsolatedHome() throws {
        do {
            try FileManager.default.createDirectory(
                at: isolatedHome,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw GrokCLIAdapterError.unsafeConfig
        }
        var info = stat()
        guard isolatedHome.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              isolatedHome.path.withCString({ Darwin.chmod($0, S_IRWXU) }) == 0 else {
            throw GrokCLIAdapterError.unsafeConfig
        }
    }

    func inspectConfigFile() throws {
        do {
            _ = try ClientConfigFileIO.inspectRegularFile(configURL)
        } catch {
            throw GrokCLIAdapterError.unsafeConfig
        }
    }

    func readOriginal() throws -> OriginalConfig {
        do {
            let file = try ClientConfigFileIO.readRegularFile(configURL)
            guard let text = String(data: file.bytes, encoding: .utf8) else {
                throw GrokCLIAdapterError.invalidConfig
            }
            return OriginalConfig(data: file.bytes, text: text, mode: Int16(file.mode))
        } catch ClientConfigFileIO.Failure.notFound {
            return OriginalConfig()
        } catch ClientConfigFileIO.Failure.tooLarge, ClientConfigFileIO.Failure.unsafe {
            throw GrokCLIAdapterError.unsafeConfig
        }
    }

    func validateUserTOML(_ text: String) throws {
        if canUseOfficialGrok() {
            let combined = try grokTOMLDiagnostics(text)
            if combined.localizedCaseInsensitiveContains("syntax errors")
                || combined.localizedCaseInsensitiveContains("TOML parse") {
                throw GrokCLIAdapterError.invalidConfig
            }
        }
        _ = try GrokUserTOML.parse(text)
    }

    func canUseOfficialGrok() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: grokExecutable.path) else { return false }
        guard let help = try? runGrok(["mcp", "add", "--help"]) else { return false }
        if help.status != 0 { return false }
        let output = String(decoding: help.stdout + help.stderr, as: UTF8.self)
        if output.contains("--scope") { return true }
        return false
    }

    func officialGrokIsUnsupported() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: grokExecutable.path) else { return false }
        guard let help = try? runGrok(["mcp", "add", "--help"]), help.status == 0 else { return false }
        let output = String(decoding: help.stdout + help.stderr, as: UTF8.self)
        return !output.contains("--scope")
    }

    func grokTOMLDiagnostics(_ text: String) throws -> String {
        return try grokTOMLDiagnostics(
            text,
            probe: makeDiagnosticsProbe(),
            removeProbe: removeDiagnosticsProbe
        )
    }

    func writeBackup(_ original: OriginalConfig) throws {
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDirectory.path)
        if let data = original.data, let mode = original.mode {
            try data.write(to: backupDataURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupDataURL.path)
            try Data("mode=\(mode)".utf8).write(to: backupStateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupStateURL.path)
        } else {
            try? FileManager.default.removeItem(at: backupDataURL)
            try Data("missing".utf8).write(to: backupStateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupStateURL.path)
        }
    }

    func clearBackup() throws {
        do {
            if FileManager.default.fileExists(atPath: backupDataURL.path) {
                try removeBackupItem(backupDataURL)
            }
            if FileManager.default.fileExists(atPath: backupStateURL.path) {
                try removeBackupItem(backupStateURL)
            }
        } catch {
            throw GrokCLIAdapterError.backupCleanupFailed
        }
    }

    func restoreBackup(_ original: OriginalConfig, expectedDigest: Data? = nil) throws {
        do {
            if let expectedDigest {
                let quarantine = configURL.deletingLastPathComponent()
                    .appendingPathComponent(".askkey-rollback-\(UUID().uuidString)")
                try renameExclusively(configURL, quarantine)
                guard Data(SHA256.hash(data: try Data(contentsOf: quarantine))) == expectedDigest else {
                    try renameExclusively(quarantine, configURL)
                    throw GrokCLIAdapterError.rollbackFailed
                }
                do {
                    if let data = original.data, let mode = original.mode {
                        try atomicWrite(data, to: configURL, mode: mode, exclusive: true)
                    }
                    try FileManager.default.removeItem(at: quarantine)
                } catch {
                    if FileManager.default.fileExists(atPath: quarantine.path),
                       !FileManager.default.fileExists(atPath: configURL.path) {
                        try renameExclusively(quarantine, configURL)
                    }
                    throw GrokCLIAdapterError.rollbackFailed
                }
            } else if let data = original.data, let mode = original.mode {
                try atomicWrite(data, to: configURL, mode: mode)
            } else if FileManager.default.fileExists(atPath: configURL.path) {
                try FileManager.default.removeItem(at: configURL)
            }
            try clearBackup()
        } catch {
            throw GrokCLIAdapterError.rollbackFailed
        }
    }

    func applyStdioConfig(originalText: String?, appliedDigest: inout Data?) throws {
        if officialGrokIsUnsupported() {
            throw GrokCLIAdapterError.unsupportedClient
        }
        try FileManager.default.createDirectory(
            at: grokHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let preservedMode = try readOriginal().mode ?? 0o600
        if canUseOfficialGrok() {
            try runOfficialCLIInIsolation(originalText: originalText)
        }
        try afterOfficialPreflight()
        try writeLosslessStdio(
            originalText: originalText,
            mode: preservedMode,
            appliedDigest: &appliedDigest
        )
        try readBackStdio()
    }

    private func runOfficialCLIInIsolation(originalText: String?) throws {
        let home = backupDirectory
            .appendingPathComponent("official-grok-\(UUID().uuidString)", isDirectory: true)
        let config = home.appendingPathComponent("config.toml")
        do {
            try FileManager.default.createDirectory(
                at: home,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if let originalText {
                try Data(originalText.utf8).write(to: config, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: config.path
                )
            }
            var isolated = self
            isolated.grokHome = home
            do { try isolated.addWithOfficialCLI() }
            catch { NSLog("AskKey: Grok official MCP add preflight failed; using lossless TOML fallback: \(error.localizedDescription)") }
            try FileManager.default.removeItem(at: home)
        } catch {
            if FileManager.default.fileExists(atPath: home.path) {
                do { try FileManager.default.removeItem(at: home) }
                catch { throw GrokCLIAdapterError.rollbackFailed }
            }
            throw error
        }
    }

    func addWithOfficialCLI() throws {
        var arguments = ["mcp", "add", "--scope", "user"]
        for (key, value) in helperEnvironment.sorted(by: { $0.key < $1.key }) {
            arguments.append(contentsOf: ["-e", "\(key)=\(value)"])
        }
        arguments.append(contentsOf: [serverName, "--", helperExecutable.path, "mcp"])
        let result = try runGrok(arguments)
        if result.status != 0 {
            throw GrokCLIAdapterError.verificationFailed("official_add")
        }
    }

    func writeLosslessStdio(
        originalText: String?,
        mode: Int16,
        appliedDigest: inout Data?
    ) throws {
        let next = try GrokUserTOML.upsertStdio(
            in: originalText ?? "",
            serverName: serverName,
            command: helperExecutable.path,
            args: ["mcp"],
            env: helperEnvironment
        )
        let replacement = Data(next.utf8)
        appliedDigest = Data(SHA256.hash(data: replacement))
        try replaceIfUnchanged(
            originalText: originalText,
            replacement: replacement,
            mode: mode
        )
        try afterReplacementWrite()
    }

    private func replaceIfUnchanged(
        originalText: String?,
        replacement: Data,
        mode: Int16
    ) throws {
        guard let originalText else {
            try atomicWrite(replacement, to: configURL, mode: mode, exclusive: true)
            return
        }
        let quarantine = configURL.deletingLastPathComponent()
            .appendingPathComponent(".askkey-input-\(UUID().uuidString)")
        try renameExclusively(configURL, quarantine)
        let currentMode = try FileManager.default.attributesOfItem(atPath: quarantine.path)[.posixPermissions] as? NSNumber
        guard try Data(contentsOf: quarantine) == Data(originalText.utf8),
              currentMode?.int16Value == mode else {
            try renameExclusively(quarantine, configURL)
            throw GrokCLIAdapterError.rollbackFailed
        }
        do {
            try atomicWrite(replacement, to: configURL, mode: mode, exclusive: true)
            try FileManager.default.removeItem(at: quarantine)
        } catch {
            if FileManager.default.fileExists(atPath: quarantine.path),
               !FileManager.default.fileExists(atPath: configURL.path) {
                try renameExclusively(quarantine, configURL)
            }
            throw GrokCLIAdapterError.rollbackFailed
        }
    }

    func readBackStdio() throws {
        try inspectConfigFile()
        let text = try String(contentsOf: configURL, encoding: .utf8)
        guard GrokUserTOML.askKeyTransport(in: text) == .stdio(command: helperExecutable.path, args: ["mcp"]) else {
            throw GrokCLIAdapterError.verificationFailed("readback")
        }
    }

    func verify(before: String) throws -> GrokCLIConnectResult {
        let after = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let diff = GrokUserTOML.redactedDiff(before: before, after: after)
        if GrokUserTOML.askKeyTransport(in: after) == .remote {
            return result(connected: false, reason: "remote_connector", diff: diff, listJSON: "", doctorJSON: "", version: "")
        }
        if GrokUserTOML.askKeyTransport(in: after) != .stdio(command: helperExecutable.path, args: ["mcp"]) {
            return result(connected: false, reason: "not_configured", diff: diff, listJSON: "", doctorJSON: "", version: "")
        }

        guard canUseOfficialGrok() else {
            return result(connected: false, reason: "list_unavailable", diff: diff, listJSON: "", doctorJSON: "", version: "")
        }
        let listed = try runGrok(["mcp", "list", "--json"])
        let listJSON = extractJSON(String(decoding: listed.stdout, as: UTF8.self))
        guard listed.status == 0, let listData = listJSON.data(using: .utf8),
              let servers = try JSONSerialization.jsonObject(with: listData) as? [[String: Any]],
              let askkey = servers.first(where: {
                  $0["name"] as? String == serverName
                      && $0["scope"] as? String != "project"
                      && $0["url"] == nil
              }),
              askkey["command"] as? String == helperExecutable.path,
              (askkey["args"] as? [String]) == ["mcp"] else {
            return result(connected: false, reason: "list_mismatch", diff: diff, listJSON: listJSON, doctorJSON: "", version: "")
        }
        let doctor = try runGrok(["mcp", "doctor", "--json", serverName])
        let doctorJSON = extractJSON(String(decoding: doctor.stdout, as: UTF8.self))
        guard doctor.status == 0, doctorHealthy(doctorJSON) else {
            return result(connected: false, reason: "doctor_unhealthy", diff: diff, listJSON: listJSON, doctorJSON: doctorJSON, version: "")
        }

        guard signing.isTrusted(helperExecutable) else {
            return result(connected: false, reason: "helper_signature", diff: diff, listJSON: listJSON, doctorJSON: doctorJSON, version: "")
        }
        let helper: (version: String, tools: [String])
        do {
            helper = try inspectHelper()
        } catch is MCPHelperContract.Failure {
            return result(
                connected: false,
                reason: "helper_initialize",
                diff: diff,
                listJSON: listJSON,
                doctorJSON: doctorJSON,
                version: ""
            )
        }
        guard helper.version == "0.1.0" else {
            return result(connected: false, reason: "helper_version", diff: diff, listJSON: listJSON, doctorJSON: doctorJSON, version: helper.version)
        }
        guard helper.tools.contains("list_credentials"), helper.tools.contains("run") else {
            return result(connected: false, reason: "helper_tools", diff: diff, listJSON: listJSON, doctorJSON: doctorJSON, version: helper.version)
        }
        guard try brokerIsHealthy() else {
            return result(connected: false, reason: "broker_unhealthy", diff: diff, listJSON: listJSON, doctorJSON: doctorJSON, version: helper.version)
        }
        return result(
            connected: true,
            reason: "ok",
            diff: diff,
            listJSON: listJSON,
            doctorJSON: doctorJSON,
            version: helper.version
        )
    }

    func result(
        connected: Bool,
        reason: String,
        diff: String,
        listJSON: String,
        doctorJSON: String,
        version: String
    ) -> GrokCLIConnectResult {
        GrokCLIConnectResult(
            connected: connected,
            reason: reason,
            diff: diff,
            listJSON: listJSON,
            doctorJSON: doctorJSON,
            helperVersion: version
        )
    }

    func doctorHealthy(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["servers"] as? [[String: Any]],
              let askkey = servers.first(where: { $0["name"] as? String == serverName }) else {
            return false
        }
        if askkey["transport"] as? String != "stdio" { return false }
        if let target = askkey["target"] as? String, target.lowercased().hasPrefix("http") { return false }
        return askkey["healthy"] as? Bool == true
    }

    func inspectHelper() throws -> (version: String, tools: [String]) {
        let ran = try runCapturedProcess(
            executable: helperExecutable,
            arguments: ["mcp"],
            environment: helperProcessEnvironment(),
            currentDirectory: isolatedHome,
            input: try MCPHelperContract.requestPayload(.grokClient),
            timeout: commandTimeout
        )
        guard ran.status == 0 else {
            throw GrokCLIAdapterError.verificationFailed("helper_initialize")
        }
        let inspected = try MCPHelperContract.inspect(
            String(decoding: ran.stdout, as: UTF8.self),
            identity: .grokClient
        )
        return (inspected.version, inspected.tools)
    }

    func brokerIsHealthy() throws -> Bool {
        let ran = try runCapturedProcess(
            executable: helperExecutable,
            arguments: ["health"],
            environment: helperProcessEnvironment(),
            currentDirectory: isolatedHome,
            timeout: commandTimeout
        )
        guard ran.status == 0 else { return false }
        let trimmed = String(decoding: ran.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return false }
        let decoded = try JSONDecoder().decode(BrokerResponse.self, from: data)
        guard case .success(.health(let health)) = decoded else { return false }
        return health.status == "ok" && health.version == BrokerProtocolVersion.current
    }

    func helperProcessEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["ASKKEY_BROKER_SOCKET"] = brokerSocketPath
        for (key, value) in helperEnvironment { env[key] = value }
        return env
    }

    func grokEnvironment(grokHomeOverride: URL?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = isolatedHome.path
        env["GROK_HOME"] = (grokHomeOverride ?? grokHome).path
        env["GROK_CURSOR_MCPS_ENABLED"] = "0"
        env["GROK_CLAUDE_MCPS_ENABLED"] = "0"
        env.removeValue(forKey: "GROK_CONFIG")
        env.removeValue(forKey: "GROK_CONFIG_PATH")
        env.removeValue(forKey: "ASKKEY_BROKER_SOCKET")
        return env
    }

    func runGrok(_ arguments: [String], grokHomeOverride: URL? = nil, timeout: TimeInterval? = nil) throws -> RunResult {
        try runCapturedProcess(
            executable: grokExecutable,
            arguments: arguments,
            environment: grokEnvironment(grokHomeOverride: grokHomeOverride),
            currentDirectory: isolatedHome,
            timeout: timeout ?? commandTimeout
        )
    }

    func runCapturedProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        input: Data? = nil,
        timeout: TimeInterval
    ) throws -> RunResult {
        let result = try runProcess(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            input: input,
            timeout: timeout,
            terminationGrace: terminationGrace,
            maximumBytes: capturedOutputLimit
        )
        outputCapture.bytes = result.stdout.count + result.stderr.count
        if result.timedOut {
            throw GrokCLIAdapterError.verificationFailed("timeout")
        }
        return result
    }

    func atomicWrite(_ data: Data, to url: URL, mode: Int16, exclusive: Bool = false) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try ClientConfigFileIO.publishAtomically(
                data,
                to: url,
                mode: mode_t(mode),
                exclusive: exclusive,
                temporaryPrefix: ".\(url.lastPathComponent).tmp-",
                didCreateTemporary: observeAtomicWriteTemporary
            )
        } catch ClientConfigFileIO.Failure.exclusiveExists {
            throw POSIXError(.EEXIST)
        } catch let error as POSIXError {
            throw error
        } catch {
            throw posixFailure()
        }
    }

    private func renameExclusively(_ source: URL, _ destination: URL) throws {
        do {
            try ClientConfigFileIO.renameExclusively(from: source, to: destination)
        } catch {
            throw GrokCLIAdapterError.rollbackFailed
        }
    }
}

private func extractJSON(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let objectStart = trimmed.firstIndex(of: "{")
    let arrayStart = trimmed.firstIndex(of: "[")
    switch (objectStart, arrayStart) {
    case let (object?, array?) where array < object:
        if let end = trimmed.lastIndex(of: "]") { return String(trimmed[array...end]) }
    case let (object?, _):
        if let end = trimmed.lastIndex(of: "}") { return String(trimmed[object...end]) }
    case let (nil, array?):
        if let end = trimmed.lastIndex(of: "]") { return String(trimmed[array...end]) }
    default:
        break
    }
    return trimmed
}

private struct RunResult {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
}

final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var bytes: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

/// Grok policy on the shared restricted process: chdir, write stdin after
/// spawn, capture stderr, truncate at the caller cap, wall clock, TERM grace,
/// then return status instead of throwing on timeout.
private func runProcess(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectory: URL,
    input: Data? = nil,
    timeout: TimeInterval,
    terminationGrace: TimeInterval,
    maximumBytes: Int
) throws -> RunResult {
    do {
        let result = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory,
                standardInput: input,
                writeInputBeforeSpawn: false,
                timeout: timeout,
                usesMonotonicClock: false,
                captureStderr: true,
                maximumOutputBytes: maximumBytes,
                truncateOutput: true,
                terminationGrace: terminationGrace
            )
        )
        return RunResult(
            status: result.status,
            stdout: result.stdout,
            stderr: result.stderr,
            timedOut: result.timedOut
        )
    } catch let failure as RestrictedProcess.Failure {
        throw failure.posixError
    }
}

private func posixFailure() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

enum GrokUserTOML {
    enum Transport: Equatable {
        case missing
        case remote
        case stdio(command: String, args: [String])
        case other
    }

    struct Table {
        var header: String
        var body: String
    }

    static func parse(_ text: String) throws -> [Table] {
        if text.contains("\0") { throw GrokCLIAdapterError.invalidConfig }
        var tables: [Table] = []
        var header = ""
        var body: [String] = []
        var arrayDepth = 0
        var objectDepth = 0
        var inMultilineBasic = false
        var inMultilineLiteral = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if inMultilineBasic {
                body.append(line)
                if countUnescaped(line, delimiter: "\"\"\"") % 2 == 1 { inMultilineBasic = false }
                continue
            }
            if inMultilineLiteral {
                body.append(line)
                if line.contains("'''") { inMultilineLiteral = false }
                continue
            }
            let trimmed = trimComment(line)
            if arrayDepth == 0 && objectDepth == 0 {
                if let next = tableHeader(trimmed) {
                    if !header.isEmpty || !body.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        tables.append(Table(header: header, body: body.joined(separator: "\n")))
                    } else if header.isEmpty && !body.isEmpty {
                        tables.append(Table(header: "", body: body.joined(separator: "\n")))
                    }
                    header = next
                    body = []
                    continue
                }
            }
            if trimmed.isEmpty {
                body.append(line)
                continue
            }
            if arrayDepth == 0 && objectDepth == 0 && !trimmed.contains("=") && !trimmed.hasPrefix("[") {
                throw GrokCLIAdapterError.invalidConfig
            }
            if let idx = trimmed.firstIndex(of: "="), arrayDepth == 0, objectDepth == 0 {
                let value = trimmed[trimmed.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                if !value.hasPrefix("\""), value.contains("[[") { throw GrokCLIAdapterError.invalidConfig }
                if value.hasPrefix("[[") { throw GrokCLIAdapterError.invalidConfig }
                if value.contains("\"\"\"") { inMultilineBasic = countUnescaped(value, delimiter: "\"\"\"") % 2 == 1 }
                if value.contains("'''") { inMultilineLiteral = true }
            }
            arrayDepth += count(trimmed, of: "[") - count(trimmed, of: "]")
            objectDepth += count(trimmed, of: "{") - count(trimmed, of: "}")
            if arrayDepth < 0 || objectDepth < 0 { throw GrokCLIAdapterError.invalidConfig }
            body.append(line)
        }
        if inMultilineBasic || inMultilineLiteral || arrayDepth != 0 || objectDepth != 0 {
            throw GrokCLIAdapterError.invalidConfig
        }
        if !header.isEmpty || !body.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tables.append(Table(header: header, body: body.joined(separator: "\n")))
        }
        return tables
    }

    static func upsertStdio(
        in text: String,
        serverName: String,
        command: String,
        args: [String],
        env: [String: String]
    ) throws -> String {
        let tables = try parse(text)
        let prefixes = [
            "mcp_servers.\(serverName)",
            "mcp_servers.\(serverName).",
        ]
        var kept: [Table] = []
        for table in tables {
            if table.header == prefixes[0] || table.header.hasPrefix(prefixes[1]) { continue }
            kept.append(table)
        }
        var rendered = kept.map { table -> String in
            if table.header.isEmpty { return table.body }
            let heading = "[\(table.header)]"
            return table.body.trimmingCharacters(in: .newlines).isEmpty
                ? heading
                : heading + "\n" + table.body.trimmingCharacters(in: CharacterSet.newlines)
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .newlines)
        var section = """
        [mcp_servers.\(serverName)]
        command = \(quote(command))
        args = [\(args.map(quote).joined(separator: ", "))]
        enabled = true
        """
        if !env.isEmpty {
            let pairs = env.sorted(by: { $0.key < $1.key })
                .map { "\($0.key) = \(quote($0.value))" }
                .joined(separator: ", ")
            section += "\nenv = { \(pairs) }"
        }
        if !rendered.isEmpty { rendered += "\n\n" }
        rendered += section
        if !rendered.hasSuffix("\n") { rendered += "\n" }
        return rendered
    }

    static func askKeyTransport(in text: String, serverName: String = "askkey") -> Transport {
        guard let tables = try? parse(text) else { return .other }
        let header = "mcp_servers.\(serverName)"
        guard let table = tables.first(where: { $0.header == header }) else { return .missing }
        var command: String?
        var remote = false
        var args: [String] = []
        var collectingArgs = false
        var argsRaw = ""
        for raw in table.body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = trimComment(String(raw))
            if collectingArgs {
                argsRaw += trimmed
                if trimmed.contains("]") {
                    collectingArgs = false
                    args = arrayValue(argsRaw)
                }
                continue
            }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "url" { remote = true }
            if key == "command" { command = unquote(value) }
            if key == "args" {
                argsRaw = value
                if value.contains("]") {
                    args = arrayValue(value)
                } else {
                    collectingArgs = true
                }
            }
        }
        if remote { return .remote }
        guard let command else { return .other }
        return .stdio(command: command, args: args)
    }

    static func redactedDiff(before: String, after: String) -> String {
        redact(before) == redact(after) ? "" : "before:\n\(redact(before))\n after:\n\(redact(after))\n"
    }

    private static func tableHeader(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.hasPrefix("[[") else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func arrayValue(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if trimmed.isEmpty { return [] }
        return trimmed.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func unquote(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
            value = value.replacingOccurrences(of: "\\\"", with: "\"")
            value = value.replacingOccurrences(of: "\\\\", with: "\\")
        }
        return value
    }

    private static func quote(_ raw: String) -> String {
        "\"" + raw.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func trimComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        for (index, character) in line.enumerated() {
            if escaped { escaped = false; continue }
            if character == "\\" && inString { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            if character == "#" && !inString {
                return String(line.prefix(index)).trimmingCharacters(in: .whitespaces)
            }
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func count(_ text: String, of character: Character) -> Int {
        var inString = false
        var escaped = false
        var total = 0
        for item in text {
            if escaped { escaped = false; continue }
            if item == "\\" && inString { escaped = true; continue }
            if item == "\"" { inString.toggle(); continue }
            if !inString && item == character { total += 1 }
        }
        return total
    }

    private static func countUnescaped(_ text: String, delimiter: String) -> Int {
        text.components(separatedBy: delimiter).count - 1
    }

    private static func redact(_ text: String) -> String {
        var insideEnvironmentTable = false
        var inlineEnvironmentDepth = 0
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let lower = line.lowercased()
            if inlineEnvironmentDepth > 0 {
                let structuralLine = trimComment(String(line))
                inlineEnvironmentDepth += count(structuralLine, of: "{")
                    - count(structuralLine, of: "}")
                inlineEnvironmentDepth = max(0, inlineEnvironmentDepth)
                return ""
            }
            if let header = tableHeader(trimComment(String(line)))?.lowercased() {
                insideEnvironmentTable = header.hasSuffix(".env") || header.contains(".env.")
                    || header.hasSuffix(".headers") || header.contains(".headers.")
                return String(line)
            }
            if let equals = line.firstIndex(of: "=") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let normalizedKey = key.filter { $0.isLetter || $0.isNumber }
                if key == "env" || normalizedKey == "headers" {
                    let value = line[line.index(after: equals)...]
                    let structuralValue = trimComment(String(value))
                    inlineEnvironmentDepth = max(
                        0,
                        count(structuralValue, of: "{") - count(structuralValue, of: "}")
                    )
                    return String(line[..<equals]) + "= \"***\""
                }
            }
            if lower.contains("authorization") || lower.contains("token")
                || lower.contains("secret") || lower.contains("api_key")
                || lower.contains("x-api-key") || lower.contains("headers")
                || lower.contains("password") || lower.contains("askkey_broker_socket")
                || lower.contains(".env.") || lower.contains(".headers.")
                || insideEnvironmentTable {
                if let eq = line.firstIndex(of: "=") {
                    return String(line[..<eq]) + "= \"***\""
                }
            }
            return String(line)
        }.joined(separator: "\n")
    }
}
