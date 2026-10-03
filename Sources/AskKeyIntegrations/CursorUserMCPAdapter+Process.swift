import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker

extension CursorUserMCPAdapter {
    func probeMCP() -> Bool {
        guard isExecutableRegularFile(helperURL), signing.isTrusted(helperURL) else { return false }
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment["ASKKEY_BROKER_SOCKET"] = brokerSocketPath
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            RuntimeOperationEvents.publish(.cursorHelper)
        } catch {
            return false
        }
        defer { stop(process) }
        do {
            try input.fileHandleForWriting.write(contentsOf: MCPHelperContract.requestPayload(.cursorClient))
            try input.fileHandleForWriting.close()
        } catch {
            return false
        }
        wait(process, until: Date().addingTimeInterval(2))
        if process.isRunning { return false }
        process.waitUntilExit()
        let response = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (try? MCPHelperContract.inspect(response, identity: .cursorClient)) != nil
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        wait(process, until: Date().addingTimeInterval(0.2))
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            wait(process, until: Date().addingTimeInterval(0.2))
        }
    }

    private func wait(_ process: Process, until deadline: Date) {
        while process.isRunning, Date() < deadline {
            if RestrictedProcessCancellation.current?() == true { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

}
