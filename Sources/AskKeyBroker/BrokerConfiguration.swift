import Foundation

public enum BrokerConfiguration {
    /// Compatibility projection for read-only path display. Explicit invalid
    /// debug isolation is never allowed to fall back to a real vault namespace.
    public static var socketURL: URL {
        (try? resolvedSocketURL()) ?? URL(fileURLWithPath: "/dev/null/askkey-invalid-debug-directory.sock")
    }

    public static func resolvedSocketURL() throws -> URL {
        if let root = try DebugRunDirectory.resolve() {
            return root.appendingPathComponent("daemon.sock")
        }
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["ASKKEY_BROKER_SOCKET"],
           override.hasPrefix("/") {
            return URL(fileURLWithPath: override)
        }
        let subdirectory = "AskKey/dev"
        #else
        let subdirectory = "AskKey"
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(subdirectory)
            .appendingPathComponent("daemon.sock")
    }
}
