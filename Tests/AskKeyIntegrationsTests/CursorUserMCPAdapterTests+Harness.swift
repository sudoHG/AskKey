import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
import AskKeyBroker
@testable import AskKeyIntegrations

extension CursorUserMCPAdapterTests {
struct Harness {
    let root: URL
    let home: URL
    let backupDirectory: URL
    let helperURL: URL
    let socketPath: String
    let adapter: CursorUserMCPAdapter
    let userConfigURL: URL
    let projectConfigURL: URL
    let cliSpecificURL: URL
    let backupURL: URL

    init(
        replaceConfig: ((URL, URL) throws -> Void)? = nil,
        removeConfig: ((URL) throws -> Void)? = nil,
        moveConfigExclusively: ((URL, URL) throws -> Void)? = nil,
        removeBackupItem: ((URL) throws -> Void)? = nil,
        helperURL: URL? = nil
    ) throws {
        let suffix = UUID().uuidString.prefix(8)
        let root = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("ak-cursor-\(ProcessInfo.processInfo.processIdentifier)-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        let cursorDir = home.appendingPathComponent(".cursor", isDirectory: true)
        let projectDir = root.appendingPathComponent("project/.cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let projectConfigURL = projectDir.appendingPathComponent("mcp.json")
        try Data(#"{ "mcpServers": { "project-only": {} } }"#.utf8).write(to: projectConfigURL)
        let helperURL = try helperURL ?? Self.locateHelper()
        let socketPath = root.appendingPathComponent("broker.sock").path
        self.root = root
        self.home = home
        self.backupDirectory = backupDirectory
        self.helperURL = helperURL
        self.socketPath = socketPath
        self.userConfigURL = cursorDir.appendingPathComponent("mcp.json")
        self.projectConfigURL = projectConfigURL
        self.cliSpecificURL = cursorDir.appendingPathComponent("cli-config.json")
        self.backupURL = backupDirectory.appendingPathComponent("cursor-mcp.json")
        self.adapter = CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: backupDirectory,
            helperURL: helperURL,
            brokerSocketPath: socketPath,
            signing: .development,
            replaceConfig: replaceConfig,
            removeConfig: removeConfig,
            moveConfigExclusively: moveConfigExclusively,
            removeBackupItem: removeBackupItem
        )
    }

    func writeUserConfig(_ text: String, permissions: Int) throws {
        try writeUserConfig(Data(text.utf8), permissions: permissions)
    }

    func writeUserConfig(_ data: Data, permissions: Int) throws {
        try FileManager.default.createDirectory(
            at: userConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: userConfigURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: userConfigURL.path
        )
    }

    func userJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: userConfigURL)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any] else {
            throw CursorMCPError.invalidJSON
        }
        return object
    }

    func permissions(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return Int(value?.uint16Value ?? 0)
    }

    func withBroker(_ body: (BrokerSocketServer) throws -> Void) throws {
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        )
        try server.start()
        defer { server.stop() }
        try body(server)
    }

    private static func locateHelper() throws -> URL {
        let url = Bundle(for: CursorUserMCPAdapterTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("askkey")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw NSError(domain: "CursorUserMCPAdapterTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "askkey helper not found at \(url.path)",
            ])
        }
        return url
    }
}
}
