import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Shared posix_spawn + private process-group + CLOEXEC + wait + group cleanup.
/// Codex and Grok keep their own timeouts, cwd, stderr, input timing, overflow,
/// and TERM grace. Cursor's long-lived Foundation Process path stays separate.
package enum RestrictedProcess {
    package static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) throws {
        _ = try run(Request(executable: executable, arguments: arguments,
                            environment: environment, timeout: timeout,
                            maximumOutputBytes: maximumOutputBytes))
    }

}
