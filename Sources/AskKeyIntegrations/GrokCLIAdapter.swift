import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker
import CryptoKit

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

}
