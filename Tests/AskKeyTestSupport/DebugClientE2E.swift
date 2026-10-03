import Foundation
import AppKit
import Darwin
import AskKeyAppKit

package struct DebugClientE2ERequest: Equatable, Sendable {
    let client: AgentClient
    let home: URL
    let output: URL

    static func parse(
        environment: [String: String],
        actualHome: URL
    ) -> Self? {
        let client: AgentClient? = switch environment["ASKKEY_CLIENT_E2E"]?.lowercased() {
        case "codex": .codex
        case "cursor": .cursor
        case "grok": .grok
        default: nil
        }
        guard let client,
              let homePath = environment["ASKKEY_CLIENT_E2E_HOME"],
              let outputPath = environment["ASKKEY_CLIENT_E2E_OUTPUT"] else { return nil }
        let home = URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
        let output = URL(fileURLWithPath: outputPath).standardizedFileURL
        var homeInfo = stat()
        guard home.path.withCString({ lstat($0, &homeInfo) }) == 0,
              homeInfo.st_mode & S_IFMT == S_IFDIR,
              homeInfo.st_uid == geteuid(),
              homeInfo.st_mode & 0o077 == 0 else { return nil }
        let resolvedHome = home.resolvingSymlinksInPath().standardizedFileURL
        let resolvedOutput = output.resolvingSymlinksInPath().standardizedFileURL
        let actual = actualHome.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedHome.path != actual,
              resolvedHome.path != "/",
              resolvedOutput.deletingLastPathComponent() == resolvedHome else { return nil }
        var outputInfo = stat()
        if resolvedOutput.path.withCString({ lstat($0, &outputInfo) }) == 0 {
            guard outputInfo.st_mode & S_IFMT == S_IFREG,
                  outputInfo.st_uid == geteuid() else { return nil }
        } else if errno != ENOENT {
            return nil
        }
        return Self(
            client: client,
            home: resolvedHome,
            output: resolvedOutput
        )
    }
}

package struct DebugClientE2EResult: Codable {
    let client: String
    let previewConnected: Bool
    let connected: Bool
    let rollback: String
    let error: String?
    var configured: Bool = false

    static func completed(client: AgentClient, connected: Bool, previewConnected: Bool = false) -> Self {
        Self(
            client: client.rawValue,
            previewConnected: previewConnected,
            connected: connected,
            rollback: connected ? "not_needed" : "completed",
            error: connected ? nil : AgentClientErrorCopy.message(for: client),
            configured: connected
        )
    }

    static func failed(client: AgentClient, error: Error) -> Self {
        Self(
            client: client.rawValue,
            previewConnected: false,
            connected: false,
            rollback: "adapter_managed",
            error: AgentClientErrorCopy.message(for: client, error: error)
        )
    }
}

enum DebugClientE2ERunner {
    @MainActor
    static func startIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ASKKEY_CLIENT_E2E"] != nil else { return false }
        guard let request = DebugClientE2ERequest.parse(
            environment: environment,
            actualHome: FileManager.default.homeDirectoryForCurrentUser
        ) else {
            fail("Ask Key client E2E request is invalid: use codex, cursor, or grok with an owner-only 0700 home and a direct result file inside it")
        }
        Task.detached {
            let connector = AgentClientConnector(
                home: request.home,
                supportDirectory: request.home.appendingPathComponent("support", isDirectory: true)
            )
            let result: DebugClientE2EResult
            do {
                let preview = try connector.preview(request.client)
                result = .completed(
                    client: request.client,
                    connected: try connector.connect(request.client),
                    previewConnected: preview.connected
                )
            } catch {
                result = .failed(client: request.client, error: error)
            }
            do {
                try FileManager.default.createDirectory(
                    at: request.home,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try JSONEncoder().encode(result).write(to: request.output, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: request.output.path
                )
            } catch {
                fail("Ask Key client E2E could not write its result: \(error.localizedDescription)")
            }
            await MainActor.run { NSApp.terminate(nil) }
        }
        return true
    }

    private static func fail(_ message: String) -> Never {
        NSLog("%@", message)
        fputs(message + "\n", stderr)
        fflush(stderr)
        // This explicit Debug harness is a command boundary; failure must be non-zero.
        Darwin.exit(EXIT_FAILURE)
    }
}
