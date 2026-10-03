import AskKeyBroker
import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
@testable import AskKeyIntegrations

extension GrokCLIAdapterTests {
final class Fixture {
    let directory: URL
    let grokHome: URL
    let isolatedHome: URL
    let workingDirectory: URL
    let backupDirectory: URL
    let helperURL: URL
    let socketPath: String
    let missingGrok: URL
    let projectConfigURL: URL
    let cursorURL: URL
    let claudeURL: URL
    var originalCursorData = Data()
    var originalClaudeData = Data()
    var originalProjectData = Data()
    private var broker: BrokerSocketServer?

    var configURL: URL { grokHome.appendingPathComponent("config.toml") }
    var backupDataURL: URL { backupDirectory.appendingPathComponent("grok-cli.config.toml") }
    var backupStateURL: URL { backupDirectory.appendingPathComponent("grok-cli.state") }

    init() throws {
        let suffix = String(UUID().uuidString.prefix(8))
        directory = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("ak-g-\(ProcessInfo.processInfo.processIdentifier)-\(suffix)", isDirectory: true)
        grokHome = directory.appendingPathComponent("g", isDirectory: true)
        isolatedHome = directory.appendingPathComponent("h", isDirectory: true)
        workingDirectory = directory.appendingPathComponent("p", isDirectory: true)
        backupDirectory = directory.appendingPathComponent("b", isDirectory: true)
        missingGrok = directory.appendingPathComponent("no-grok")
        projectConfigURL = workingDirectory.appendingPathComponent(".grok/config.toml")
        cursorURL = isolatedHome.appendingPathComponent(".cursor/mcp.json")
        claudeURL = isolatedHome.appendingPathComponent(".claude.json")
        let socketCandidate = URL(fileURLWithPath: "/private/tmp/ak-gs-\(ProcessInfo.processInfo.processIdentifier)-\(suffix)")
        try FileManager.default.createDirectory(at: socketCandidate, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let socketRoot = try physicalTestDirectory(socketCandidate)
        socketPath = socketRoot.appendingPathComponent("daemon.sock").path
        helperURL = try Self.askkeyHelper()
        for url in [grokHome, isolatedHome, workingDirectory, backupDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: projectConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        originalProjectData = Data("[mcp_servers.askkey]\nurl = \"https://project.example/mcp\"\n".utf8)
        try originalProjectData.write(to: projectConfigURL)
    }

    deinit {
        broker?.stop()
        try? FileManager.default.removeItem(at: directory)
        socketPath.withCString { _ = unlink($0) }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: socketPath).deletingLastPathComponent())
    }

    func adapter(
        grokExecutable: URL? = nil,
        brokerSocketPath: String? = nil,
        signing: CodexHelperSigning = .development,
        removeDiagnosticsProbe: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) -> GrokCLIAdapter {
        GrokCLIAdapter(
            grokHome: grokHome,
            isolatedHome: isolatedHome,
            helperExecutable: helperURL,
            grokExecutable: grokExecutable ?? missingGrok,
            backupDirectory: backupDirectory,
            brokerSocketPath: brokerSocketPath ?? socketPath,
            signing: signing,
            helperEnvironment: ["ASKKEY_BROKER_SOCKET": brokerSocketPath ?? socketPath,
                                "ASKKEY_DEBUG_RUN_DIRECTORY": URL(fileURLWithPath: brokerSocketPath ?? socketPath).deletingLastPathComponent().path],
            serverName: "askkey",
            removeDiagnosticsProbe: removeDiagnosticsProbe
        )
    }

    func startBroker() throws {
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        )
        try server.start()
        broker = server
    }

    func stopBroker() {
        broker?.stop()
        broker = nil
    }

    func posixMode(at url: URL) throws -> Int16 {
        guard let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return value.int16Value
    }

    func writeStdioAskKeyConfig() throws {
        try Data(
            """
            [mcp_servers.askkey]
            command = "\(helperURL.path)"
            args = ["mcp"]
            enabled = true
            """.utf8
        ).write(to: configURL)
    }

    func writeExecutable(name: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func writeSupportedGrok() throws -> URL {
        try writeExecutable(
            name: "supported-grok",
            contents: """
            #!/bin/sh
            config="$GROK_HOME/config.toml"
            expected_helper="\(helperURL.path)"

            if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
              printf '%s\\n' '--scope user'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "add" ]; then
              [ "$3" = "--scope" ] && [ "$4" = "user" ] || exit 64
              found_helper=0
              while [ "$#" -gt 0 ]; do
                if [ "$1" = "--" ]; then
                  shift
                  [ "$1" = "$expected_helper" ] || exit 64
                  shift
                  [ "$1" = "mcp" ] || exit 64
                  found_helper=1
                  break
                fi
                shift
              done
              [ "$found_helper" -eq 1 ] || exit 64
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "list" ] && [ "$3" = "--json" ]; then
              if [ -f "$config" ] && grep -Fq "command = \\\"$expected_helper\\\"" "$config"; then
                printf '[{"command":"%s","args":["mcp"],"enabled":true,"name":"askkey","scope":"user"}]\\n' "$expected_helper"
              else
                printf '[]\\n'
              fi
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "doctor" ] && [ "$3" = "--json" ]; then
              if [ -f "$config" ] && grep -Fq "command = \\\"$expected_helper\\\"" "$config"; then
                printf '{"servers":[{"name":"askkey","transport":"stdio","target":"askkey mcp","healthy":true}],"healthy_count":1,"failing_count":0}\\n'
                exit 0
              fi
              printf '{"servers":[{"name":"askkey","transport":"stdio","target":"askkey mcp","healthy":false}],"healthy_count":0,"failing_count":1}\\n'
              exit 1
            fi
            exit 64
            """
        )
    }

    func writeCompatAskKeyServers() throws {
        try FileManager.default.createDirectory(
            at: cursorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        originalCursorData = Data(
            """
            {"mcpServers":{"askkey":{"url":"https://cursor.example/mcp"}}}
            """.utf8
        )
        originalClaudeData = Data(
            """
            {"mcpServers":{"askkey":{"url":"https://claude.example/mcp"}}}
            """.utf8
        )
        try originalCursorData.write(to: cursorURL)
        try originalClaudeData.write(to: claudeURL)
    }

    func compatCursorData() throws -> Data { try Data(contentsOf: cursorURL) }
    func compatClaudeData() throws -> Data { try Data(contentsOf: claudeURL) }

    func projectConfigChanged() throws -> Bool {
        try Data(contentsOf: projectConfigURL) != originalProjectData
    }

    private static func askkeyHelper() throws -> URL {
        let url = Bundle(for: GrokCLIAdapterTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("askkey")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw NSError(domain: "GrokCLIAdapterTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "askkey helper is not built at \(url.path)",
            ])
        }
        return url
    }
}

}
