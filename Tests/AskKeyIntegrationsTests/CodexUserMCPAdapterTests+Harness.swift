import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeySystem

extension CodexUserMCPAdapterTests {
final class Harness {
    static let secret = "ghp_live_token_do_not_log"

    let root: URL
    let home: URL
    let project: URL
    let configURL: URL
    let projectConfigURL: URL
    let backupDirectory: URL
    let helperURL: URL
    let socketPath: String
    let cli: FakeCodexCLI
    let adapter: CodexUserMCPAdapter
    private let server: BrokerSocketServer?
    private let realHomeCodex: URL
    private let homeCodexStamp: Stamp?

    var wroteHomeCodex: Bool {
        Stamp(url: realHomeCodex) != homeCodexStamp
    }

    var wroteProjectConfig: Bool {
        (try? String(contentsOf: projectConfigURL, encoding: .utf8))?.contains("askkey") == true
    }

    var backupExists: Bool {
        FileManager.default.fileExists(atPath: backupDirectory.appendingPathComponent("config.toml").path)
    }

    var backupFileCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: backupDirectory.path).count) ?? 0
    }

    init(
        cli: FakeCodexCLI.Kind = .missing,
        brokerHealth: String = "ok",
        trustHelper: Bool = true,
        helperOverride: URL? = nil
    ) throws {
        let suffix = UUID().uuidString.prefix(8)
        root = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("akc-\(ProcessInfo.processInfo.processIdentifier)-\(suffix)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        configURL = CodexUserMCP.userConfigURL(home: home)
        projectConfigURL = project.appendingPathComponent(".codex/config.toml")
        backupDirectory = CodexUserMCP.managedBackupDirectory(
            applicationSupport: root.appendingPathComponent("AskKey", isDirectory: true)
        )
        socketPath = root.appendingPathComponent("broker.sock").path
        if let helperOverride {
            self.helperURL = helperOverride
        } else {
            self.helperURL = try Self.locateHelper()
        }
        realHomeCodex = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        homeCodexStamp = Stamp(url: realHomeCodex)

        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fake = FakeCodexCLI(kind: cli, helperURL: helperURL, configURL: configURL)
        self.cli = fake

        if brokerHealth == "ok" {
            let server = BrokerSocketServer(
                socketPath: socketPath,
                handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil })
            )
            try server.start()
            self.server = server
        } else {
            self.server = nil
        }

        adapter = CodexUserMCPAdapter(
            configURL: configURL,
            helperURL: helperURL,
            backupDirectory: backupDirectory,
            brokerSocketPath: socketPath,
            command: fake.command,
            signing: CodexHelperSigning { _ in trustHelper }
        )
    }

    func close() {
        // Probes can retain their fixture. Break those cycles before cleanup.
        adapter.lifecycle = CodexApplyLifecycle()
        server?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    deinit { close() }

    func stopBroker() {
        server?.stop()
    }

    func makeAdapter(command: CodexMCPCommand) -> CodexUserMCPAdapter {
        CodexUserMCPAdapter(
            configURL: configURL, helperURL: helperURL, backupDirectory: backupDirectory,
            brokerSocketPath: socketPath, command: command, signing: .development
        )
    }

    func writeConfig(_ text: String, mode: Int) throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: configURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: configURL.path
        )
    }

    func writeProjectConfig(_ text: String) throws {
        try Data(text.utf8).write(to: projectConfigURL)
    }

    func configText() throws -> String {
        try String(contentsOf: configURL, encoding: .utf8)
    }

    func projectConfigText() throws -> String {
        try String(contentsOf: projectConfigURL, encoding: .utf8)
    }

    func configMode() throws -> Int {
        try Self.mode(configURL)
    }

    func backupMode() throws -> Int {
        try Self.mode(backupDirectory.appendingPathComponent("config.toml"))
    }

    func backupDirectoryMode() throws -> Int {
        try Self.mode(backupDirectory)
    }

    func backupText() throws -> String {
        let url = backupDirectory.appendingPathComponent("config.toml")
        let data = try Data(contentsOf: url)
        if let backup = try? JSONDecoder().decode(CodexRollbackBackup.self, from: data) {
            return backup.originalText
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func mode(_ url: URL) throws -> Int {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw CocoaError(.fileNoSuchFile) }
        return Int(st.st_mode & 0o777)
    }

    private static func locateHelper() throws -> URL {
        let url = Bundle(for: CodexUserMCPAdapterTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("askkey")
        if FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private struct Stamp: Equatable {
        var exists: Bool
        var size: Int?
        var mtime: Int64?

        init?(url: URL) {
            var st = stat()
            if lstat(url.path, &st) != 0 {
                exists = false
                size = nil
                mtime = nil
                return
            }
            exists = true
            size = Int(st.st_size)
            mtime = Int64(st.st_mtimespec.tv_sec)
        }
    }
}

}
