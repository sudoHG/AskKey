import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

extension CodexUserMCPAdapter {
    func runOfficialCLIInIsolation(original: CodexOriginalConfig?) throws {
        let directory = backupDirectory
            .appendingPathComponent("official-cli-\(UUID().uuidString)", isDirectory: true)
        let isolatedConfig = directory.appendingPathComponent("config.toml")
        do {
            try ensureDirectory(directory, mode: 0o700, excludeFromBackup: true)
            if let original {
                try Data(original.text.utf8).write(to: isolatedConfig, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: isolatedConfig.path
                )
            }
            try command.addAskKey(helperURL, isolatedConfig)
            try FileManager.default.removeItem(at: directory)
        } catch {
            do {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
            } catch {
                throw CodexUserMCPError.rollbackFailed
            }
            throw error
        }
    }
}
/// Codex policy on the shared restricted process: pre-write stdin, 4096-byte
/// input cap, monotonic 2s budget, stdout only, 1MiB overflow as failure,
/// immediate group kill. Format and error mapping stay here.
func runProcess(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    standardInput: Data = Data()
) throws -> String {
    func failure() -> CodexUserMCPError { .connectionFailed("cli") }
    do {
        let result = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput,
                writeInputBeforeSpawn: true,
                maximumInputBytes: 4096,
                timeout: 2,
                usesMonotonicClock: true,
                captureStderr: false,
                maximumOutputBytes: 1_048_576,
                truncateOutput: false,
                terminationGrace: 0
            )
        )
        guard !result.timedOut, result.status == 0 else { throw failure() }
        return String(decoding: result.stdout, as: UTF8.self)
    } catch is RestrictedProcess.Failure {
        throw failure()
    }
}
