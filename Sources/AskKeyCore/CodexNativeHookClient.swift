import Darwin
import Foundation

public enum CodexNativeHookStatus: Equatable, Sendable {
    case missing, enabled, disabled, untrusted, unsupported
}

public enum CodexNativeHookClientError: Error, Equatable, Sendable {
    case cliMissing, userHomeMismatch, unsupported, invalidResponse, unsafeConfiguration
    case configurationChanged, verificationFailed, cancelled, timedOut, communicationFailed
    case writeOutcomeUnknown
}

/// Reads Codex's own hook state and enables only the reviewed Ask Key rule.
/// No model is started, and no HOME/CODEX_HOME override is used.
public struct CodexNativeHookClient: Sendable {
    public let executable: URL
    public let userHome: URL

    public init(executable: URL, userHome: URL) {
        self.executable = executable
        self.userHome = userHome.standardizedFileURL
    }

    private var codexHome: URL { userHome.appendingPathComponent(".codex") }
    private var hooksURL: URL { codexHome.appendingPathComponent("hooks.json") }
    private var configURL: URL { codexHome.appendingPathComponent("config.toml") }

    public func status() throws -> CodexNativeHookStatus {
        do {
            return try withSession { rpc in
                let snapshot = try reviewedSnapshot()
                let metadata = try hookMetadata(rpc, snapshot: snapshot)
                return Self.state(metadata)
            }
        } catch CodexNativeHookClientError.unsupported {
            return .unsupported
        }
    }

    @discardableResult
    public func enableReviewedHook(backupDirectory: URL? = nil) throws -> CodexNativeHookStatus {
        try withSession { rpc in
            guard let reviewed = try reviewedSnapshot() else {
                throw CodexNativeHookClientError.verificationFailed
            }
            let original = try safeConfig()
            let before = try userLayer(rpc)
            guard let metadata = try hookMetadata(rpc, snapshot: reviewed),
                  let key = metadata["key"] as? String,
                  let hash = metadata["currentHash"] as? String else {
                throw CodexNativeHookClientError.invalidResponse
            }
            if Self.state(metadata) == .enabled { return .enabled }
            let directory = backupDirectory ?? userHome.appendingPathComponent(
                "Library/Application Support/AskKey/client-backups/codex-trust"
            )
            try Self.ensureDirectory(directory)
            var directoryInfo = stat()
            guard lstat(directory.path, &directoryInfo) == 0,
                  directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & S_IFMT == S_IFDIR else {
                throw CodexNativeHookClientError.unsafeConfiguration
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var managedDirectory = directory
            try managedDirectory.setResourceValues(excluded)
            let backup = directory.appendingPathComponent("config-\(UUID().uuidString).toml")
            try ClientConfigFileIO.publishAtomically(original.bytes, to: backup, mode: 0o600,
                                                    exclusive: true, temporaryPrefix: ".askkey-trust-")
            let current = try safeConfig()
            guard current.bytes == original.bytes, current.mode == original.mode,
                  try reviewedSnapshot()?.bytes == reviewed.bytes else {
                throw CodexNativeHookClientError.configurationChanged
            }
            do {
                _ = try rpc.call("config/batchWrite", [
                "filePath": configURL.path,
                "expectedVersion": before.version,
                "reloadUserConfig": true,
                "edits": [["keyPath": "hooks.state", "mergeStrategy": "upsert", "value": [
                    key: ["enabled": true, "trusted_hash": hash]
                ]]]
                ])
                let after = try userLayer(rpc)
                guard try Self.normalized(before.config, removing: key) == Self.normalized(after.config, removing: key),
                      let readback = try hookMetadata(rpc, snapshot: reviewed),
                      readback["currentHash"] as? String == hash,
                      Self.state(readback) == .enabled else {
                    throw CodexNativeHookClientError.verificationFailed
                }
            } catch {
                // The request may have been applied before its response was
                // lost. A fresh read is required before another write.
                throw CodexNativeHookClientError.writeOutcomeUnknown
            }
            return .enabled
        }
    }

    private struct Snapshot: Equatable {
        let bytes: Data
        let key: String
    }

    private func reviewedSnapshot() throws -> Snapshot? {
        // The file adapter validates the full definition, including input,
        // and rejects duplicate/customized Ask Key rules.
        let configuration = CodexDiscoveryHookConfiguration(
            hooksURL: hooksURL, backupDirectory: codexHome.appendingPathComponent("unused")
        )
        guard try configuration.hasExpectedHook() else { return nil }
        let bytes = try ClientConfigFileIO.readRegularFile(hooksURL, maximumBytes: 1_048_576).bytes
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let groups = hooks["PreToolUse"] as? [[String: Any]],
              let index = groups.firstIndex(where: { group in
                  guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                  return handlers.contains { $0["server"] as? String == "askkey"
                      && $0["tool"] as? String == "credential_discovery_guard" }
              }),
              try configuration.hasExpectedHook(),
              try ClientConfigFileIO.readRegularFile(hooksURL).bytes == bytes else {
            throw CodexNativeHookClientError.configurationChanged
        }
        return Snapshot(bytes: bytes, key: "\(hooksURL.path):pre_tool_use:\(index):0")
    }

    private func hookMetadata(_ rpc: RPC, snapshot: Snapshot?) throws -> [String: Any]? {
        let result = try rpc.call("hooks/list", ["cwds": [userHome.path]])
        guard let entries = result["data"] as? [[String: Any]], entries.count == 1,
              let entry = entries.first,
              let errors = entry["errors"] as? [Any], errors.isEmpty,
              let hooks = entry["hooks"] as? [[String: Any]] else {
            throw CodexNativeHookClientError.invalidResponse
        }
        let matches = hooks.filter {
            $0["sourcePath"] as? String == hooksURL.path
                && $0["server"] as? String == "askkey"
                && $0["tool"] as? String == "credential_discovery_guard"
        }
        guard let snapshot else {
            guard matches.isEmpty, try reviewedSnapshot() == nil else {
                throw CodexNativeHookClientError.configurationChanged
            }
            return nil
        }
        guard matches.count == 1, let own = matches.first,
              own["key"] as? String == snapshot.key,
              own["source"] as? String == "user",
              own["isManaged"] as? Bool == false,
              own["eventName"] as? String == "preToolUse",
              own["handlerType"] as? String == "mcpTool",
              own["matcher"] as? String == "^(Bash|mcp__askkey__list_credentials)$",
              own["timeoutSec"] as? Int == 3,
              let hash = own["currentHash"] as? String,
              hash.hasPrefix("sha256:"), hash.count == 71,
              hash.dropFirst(7).allSatisfy({ $0.isHexDigit }),
              own["enabled"] is Bool,
              ["trusted", "untrusted"].contains(own["trustStatus"] as? String ?? ""),
              try reviewedSnapshot()?.bytes == snapshot.bytes else {
            throw CodexNativeHookClientError.verificationFailed
        }
        return own
    }

    private static func state(_ metadata: [String: Any]?) -> CodexNativeHookStatus {
        guard let metadata else { return .missing }
        if metadata["trustStatus"] as? String != "trusted" { return .untrusted }
        return metadata["enabled"] as? Bool == true ? .enabled : .disabled
    }

    private func userLayer(_ rpc: RPC) throws -> (version: String, config: [String: Any]) {
        let result = try rpc.call("config/read", ["includeLayers": true])
        guard let layers = result["layers"] as? [[String: Any]] else {
            throw CodexNativeHookClientError.invalidResponse
        }
        let users = layers.filter { ($0["name"] as? [String: Any])?["type"] as? String == "user" }
        guard users.count == 1, let layer = users.first,
              let name = layer["name"] as? [String: Any], name["file"] as? String == configURL.path,
              let version = layer["version"] as? String, !version.isEmpty,
              let config = layer["config"] as? [String: Any],
              layer["disabledReason"] == nil || layer["disabledReason"] is NSNull else {
            throw CodexNativeHookClientError.userHomeMismatch
        }
        return (version, config)
    }

    private func safeConfig() throws -> (bytes: Data, mode: Int) {
        do {
            let file = try ClientConfigFileIO.readRegularFile(configURL, maximumBytes: 1_048_576)
            return (file.bytes, Int(file.mode))
        } catch { throw CodexNativeHookClientError.unsafeConfiguration }
    }

    private static func normalized(_ input: [String: Any], removing key: String) throws -> Data {
        var config = input
        if var hooks = config["hooks"] as? [String: Any] {
            if var state = hooks["state"] as? [String: Any] {
                state.removeValue(forKey: key)
                if state.isEmpty { hooks.removeValue(forKey: "state") } else { hooks["state"] = state }
            }
            if hooks.isEmpty { config.removeValue(forKey: "hooks") } else { config["hooks"] = hooks }
        }
        return try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    }

    private static func ensureDirectory(_ url: URL) throws {
        try CodexHookDirectorySafety.inspect(url, error: CodexNativeHookClientError.unsafeConfiguration)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw CodexNativeHookClientError.unsafeConfiguration }
            return
        }
        guard errno == ENOENT, url.path != "/" else { throw CodexNativeHookClientError.unsafeConfiguration }
        try ensureDirectory(url.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    private func withSession<T>(_ action: (RPC) throws -> T) throws -> T {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CodexNativeHookClientError.cliMissing
        }
        do {
            let session = try RestrictedProcess.startInteractive(.init(
                executable: executable, arguments: ["app-server", "--disable", "plugins", "--disable", "apps"],
                environment: ProcessInfo.processInfo.environment, currentDirectory: userHome,
                timeout: 10, maximumInputBytes: 1_048_576, maximumOutputBytes: 4_194_304
            ))
            defer { session.close() }
            let rpc = RPC(session: session)
            let info = try rpc.call("initialize", [
                "clientInfo": ["name": "askkey-onboarding", "version": "1"],
                "capabilities": ["experimentalApi": true]
            ])
            guard info["codexHome"] as? String == codexHome.path else {
                throw CodexNativeHookClientError.userHomeMismatch
            }
            try rpc.notify("initialized")
            return try action(rpc)
        } catch let error as RestrictedProcess.InteractiveFailure {
            switch error {
            case .cancelled: throw CodexNativeHookClientError.cancelled
            case .timedOut: throw CodexNativeHookClientError.timedOut
            default: throw CodexNativeHookClientError.communicationFailed
            }
        }
    }

    private final class RPC {
        let session: RestrictedProcess.InteractiveSession
        var nextID = 0
        init(session: RestrictedProcess.InteractiveSession) { self.session = session }

        func notify(_ method: String) throws {
            try session.writeLine(JSONSerialization.data(withJSONObject: ["method": method]))
        }

        func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            nextID += 1
            let id = nextID
            try session.writeLine(JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]))
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            var bytes = 0
            while ProcessInfo.processInfo.systemUptime < deadline {
                let line = try session.readLine()
                bytes += line.count
                guard bytes <= 4_194_304,
                      let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CodexNativeHookClientError.invalidResponse
                }
                guard message["id"] as? Int == id else { continue }
                if let error = message["error"] as? [String: Any] {
                    if error["code"] as? Int == -32601 { throw CodexNativeHookClientError.unsupported }
                    throw CodexNativeHookClientError.communicationFailed
                }
                guard let result = message["result"] as? [String: Any] else {
                    throw CodexNativeHookClientError.invalidResponse
                }
                return result
            }
            throw CodexNativeHookClientError.timedOut
        }
    }
}
