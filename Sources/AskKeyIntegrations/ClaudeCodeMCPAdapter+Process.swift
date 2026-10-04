import Foundation
import AskKeyBroker
import AskKeySystem

extension ClaudeCodeMCPAdapter {
    func processEnvironment() -> [String: String] {
        // Do not inherit tokens, Claude configuration overrides, shell startup
        // variables, or loader injection from the app's environment.
        [
            "HOME": homeDirectory.path,
            "PATH": executableSearchPath,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "NO_COLOR": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "DISABLE_AUTOUPDATER": "1",
            "ASKKEY_BROKER_SOCKET": brokerSocketPath,
        ]
    }

    func runClaude(_ arguments: [String], cleanup: Bool = false) throws -> RestrictedProcess.Result {
        try run(executable: claudeExecutable, arguments: arguments, cleanup: cleanup)
    }

    func run(
        executable: URL, arguments: [String], input: Data? = nil, cleanup: Bool = false
    ) throws -> RestrictedProcess.Result {
        if !cleanup, RestrictedProcessCancellation.current?() == true {
            throw ClaudeCodeMCPError.cancelled
        }
        do {
            let result = try RestrictedProcess.run(.init(
                executable: executable,
                arguments: arguments,
                environment: processEnvironment(),
                currentDirectory: workingDirectory,
                standardInput: input,
                timeout: commandTimeout,
                usesMonotonicClock: true,
                maximumOutputBytes: BrokerLimits.maximumResponseBytes,
                truncateOutput: false,
                terminationGrace: terminationGrace,
                isCancelled: cleanup ? { false } : RestrictedProcessCancellation.current
            ))
            guard !result.timedOut else { throw ClaudeCodeMCPError.timeout }
            return result
        } catch RestrictedProcess.Failure.cancelled {
            throw ClaudeCodeMCPError.cancelled
        } catch RestrictedProcess.Failure.outputTooLarge {
            throw ClaudeCodeMCPError.outputTooLarge
        } catch is RestrictedProcess.Failure {
            throw ClaudeCodeMCPError.processFailed
        }
    }

    func preflight() throws -> String {
        guard FileManager.default.isExecutableFile(atPath: claudeExecutable.path) else {
            throw ClaudeCodeMCPError.missingExecutable
        }
        let reported = try runClaude(["--version"])
        let text = String(decoding: reported.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard reported.status == 0,
              text.range(of: #"^\d+\.\d+\.\d+ \(Claude Code\)$"#, options: .regularExpression) != nil,
              let version = text.split(separator: " ").first.map(String.init),
              version.compare(Self.minimumVersion, options: .numeric) != .orderedAscending else {
            throw ClaudeCodeMCPError.unsupportedVersion
        }
        for command in ["add-json", "remove", "get", "list"] {
            let help = try runClaude(["mcp", command, "--help"])
            let output = String(decoding: help.stdout, as: UTF8.self)
            guard help.status == 0, output.contains("Usage:"), output.contains(command) else {
                throw ClaudeCodeMCPError.unsupportedCLI
            }
            if command == "add-json" || command == "remove" {
                guard output.contains("--scope"), output.contains("user") else {
                    throw ClaudeCodeMCPError.unsupportedCLI
                }
            }
        }
        return version
    }
}
