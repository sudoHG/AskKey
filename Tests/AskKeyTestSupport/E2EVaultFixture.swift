import CryptoKit
import Foundation
import AskKeyBroker
import AskKeyVault

/// Real, process-restartable storage used only by the isolated E2E app build.
/// The key is deliberately fixed test material; it is never a production key.
enum VaultE2EFixture {
    private static let fixedTestKey = SymmetricKey(data: Data(repeating: 0xA5, count: 32))

    static func makeVault() -> Vault {
        let environment = ProcessInfo.processInfo.environment
        guard let debugPath = environment["ASKKEY_DEBUG_RUN_DIRECTORY"],
              let e2ePath = environment["ASKKEY_E2E_RUN_DIRECTORY"],
              !debugPath.isEmpty,
              debugPath == e2ePath else {
            fatalError(
                "AskKey E2E requires ASKKEY_DEBUG_RUN_DIRECTORY and "
                    + "ASKKEY_E2E_RUN_DIRECTORY to name the same isolated directory."
            )
        }

        do {
            guard let directory = try DebugRunDirectory.resolve() else {
                fatalError("AskKey E2E requires a valid isolated Debug run directory.")
            }
            let requested = URL(fileURLWithPath: debugPath, isDirectory: true)
                .standardizedFileURL
            guard directory.standardizedFileURL.path == requested.path else {
                fatalError("AskKey E2E run directory did not pass isolation validation.")
            }

            let databaseURL = directory.appendingPathComponent("e2e-vault.db")
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let path = databaseURL.path + suffix
                if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                   attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    fatalError("E2E database files must not be symbolic links")
                }
            }
            let store = try VaultStore(path: databaseURL.path)
            let fileDeliveryManager = try FileDeliveryManager.configured(
                rootURL: directory.appendingPathComponent("deliveries", isDirectory: true)
            )
            let vault = Vault(store: store, key: fixedTestKey, fileDeliveryManager: fileDeliveryManager)
            if let scenario = environment["ASKKEY_E2E_SCENARIO"], scenario.hasPrefix("approval") {
                try vault.beginManagementSession(using: .allow)
                defer { vault.endManagementSession() }
                let credential: TextCredentialInput = scenario == E2EScreenshotDemo.scenario
                    ? .init(name: E2EScreenshotDemo.credentialName, value: E2EScreenshotDemo.syntheticValue,
                            environmentVariable: E2EScreenshotDemo.environmentVariable, permission: .ask)
                    : .init(name: "E2E Broker Credential", value: "synthetic-e2e-value",
                            environmentVariable: "ASKKEY_E2E_TOKEN", permission: .ask)
                if try !vault.listTextCredentials().contains(where: { $0.name == credential.name }) {
                    _ = try vault.createTextCredential(credential, using: .allow)
                }
            }
            return vault
        } catch {
            fatalError("AskKey E2E isolated vault could not be opened: \(error)")
        }
    }
}
