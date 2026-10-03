import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker
import CryptoKit

extension GrokCLIAdapter {
    func helperProcessEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["ASKKEY_BROKER_SOCKET"] = brokerSocketPath
        for (key, value) in helperEnvironment { env[key] = value }
        return env
    }

    private func grokEnvironment(grokHomeOverride: URL?) -> [String: String] {
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