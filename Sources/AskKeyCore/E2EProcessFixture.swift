#if DEBUG && ASKKEY_E2E_TESTING
import Foundation

public enum E2EProcessFixture {
    public static func runSlowCommand(in directory: URL) throws {
        guard VaultConfiguration.debugRunDirectory == directory else {
            preconditionFailure("E2E process fixture requires the isolated run directory")
        }
        _ = try RestrictedProcess.run(.init(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo $$ > \"$ASKKEY_E2E_RUN_DIRECTORY/hang.pid\"; exec /bin/sleep 30"],
            environment: ["PATH": "/usr/bin:/bin", "ASKKEY_E2E_RUN_DIRECTORY": directory.path],
            timeout: 35,
            maximumOutputBytes: 1_024
        ))
    }
}
#endif
