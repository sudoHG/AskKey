import Foundation

/// Demo data for the README screenshots run (`approval-screenshots`) only.
/// The required flows keep their own fixture names, paths and commands.
enum E2EScreenshotDemo {
    static let scenario = "approval-screenshots"
    static let credentialName = "Staging API"
    static let syntheticValue = "synthetic-staging-value"
    static let environmentVariable = "STAGING_API_TOKEN"

    /// Run arguments the approval prompt renders as "to run ./deploy.sh" in
    /// `~/web`. Creates that directory, so the caller must pass the returned
    /// workspace to `removeWorkspace(_:)` when the scenario ends.
    static func makeRun(operationID: String) throws -> (arguments: [String: Any], workspace: URL) {
        let workspace = try createWorkspace()
        let arguments: [String: Any] = [
            "operation_id": operationID,
            "credentials": [credentialName],
            "command": ["./deploy.sh"],
            "cwd": workspace.path, "caller_name": "Claude Code", "caller_purpose": "Deploy the staging site"
        ]
        return (arguments, workspace)
    }

    static func removeWorkspace(_ workspace: URL) {
        try? FileManager.default.removeItem(at: workspace)
    }

    private static func createWorkspace() throws -> URL {
        let workspace = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("web", isDirectory: true)
        // Never reuse or later delete a directory this run did not create.
        guard !FileManager.default.fileExists(atPath: workspace.path) else {
            throw NSError(domain: "AskKeyE2E", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Screenshot demo needs ~/web to be absent; it already exists"
            ])
        }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let script = """
        #!/bin/sh
        set -eu
        [ "${\(environmentVariable):-}" = \(syntheticValue) ] || exit 42
        printf 'Deployed to staging\\n'
        """
        let scriptURL = workspace.appendingPathComponent("deploy.sh")
        do {
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            removeWorkspace(workspace)
            throw error
        }
        return workspace
    }
}
