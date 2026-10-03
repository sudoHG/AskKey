import Foundation
import Darwin

extension RestrictedProcess {
    /// The small interactive boundary used by native app-server clients.
    ///
    /// This deliberately shares the same spawn topology as `run`: the child
    /// gets a private process group, inherited descriptors are closed by
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT`, and cleanup always covers the group.
    /// It is line-oriented because app-server speaks JSONL, and it never uses
    /// Foundation's `Process` abstraction.
    package struct InteractiveRequest: Sendable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
        var currentDirectory: URL? = nil
        var timeout: TimeInterval
        var maximumInputBytes: Int
        var maximumOutputBytes: Int
        var terminationGrace: TimeInterval = 0
        var isCancelled: (@Sendable () -> Bool)? = nil

        package init(
            executable: URL,
            arguments: [String],
            environment: [String: String],
            currentDirectory: URL? = nil,
            timeout: TimeInterval,
            maximumInputBytes: Int,
            maximumOutputBytes: Int,
            terminationGrace: TimeInterval = 0,
            isCancelled: (@Sendable () -> Bool)? = nil
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.currentDirectory = currentDirectory
            self.timeout = timeout
            self.maximumInputBytes = maximumInputBytes
            self.maximumOutputBytes = maximumOutputBytes
            self.terminationGrace = terminationGrace
            self.isCancelled = isCancelled
        }
    }
}
