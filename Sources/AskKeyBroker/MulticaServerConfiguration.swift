import Foundation

/// The stdio configuration shared by the App and the helper when they hand
/// Ask Key's MCP server to Multica.
public struct MulticaServerConfiguration: Codable, Equatable, Sendable {
    public let command: String
    public let args: [String]
    public let env: [String: String]?

    public init(command: String, args: [String], env: [String: String]? = nil) {
        self.command = command
        self.args = args
        self.env = env
    }

    /// Builds the configuration for the current process. In a Debug build,
    /// an invalid isolation root is deliberately surfaced by
    /// `DebugRunDirectory.resolve` instead of being silently omitted.
    public static func make(
        command: String,
        args: [String] = ["mcp"],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Self {
        #if DEBUG
        let env = try DebugRunDirectory.resolve(
            environment: environment,
            homeDirectory: homeDirectory
        ).map { ["ASKKEY_DEBUG_RUN_DIRECTORY": $0.path] }
        #else
        let env: [String: String]? = nil
        #endif
        return Self(command: command, args: args, env: env)
    }
}
