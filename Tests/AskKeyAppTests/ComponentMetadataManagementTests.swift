import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class ComponentMetadataManagementTests: AskKeyAppTestCase {
    func testManagementRetainsRowsAndShowsActionableLocalizedMetadataFailureWithoutPolicyRecovery() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        try library.vault.beginManagementSession(using: .allow)
        let credential = try library.vault.createTextCredential(.init(name: "Synthetic affected", value: "synthetic-private-value"), using: .allow)
        for reason in [ComponentMetadataUpgradeError.Reason.backfill, .integrity] {
            let issue = ComponentMetadataUpgradeError(reason: reason, credentialNames: [credential.name])
            var mutations = CredentialWorkspaceMutations.readOnly { ([credential], [], [], false) }
            mutations.componentMetadataIssue = { issue }
            let suite = "ComponentMetadataManagement-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = VaultViewModel(runtimeFileCleanupFailures: { false }, accessRecords: .empty,
                eraseLocalLibrary: { _, _, _ in }, unlockVault: {}, beginManagementSession: { _ in },
                authenticateDeviceOwner: { _ in .allow }, preferences: AppPreferences(defaults: defaults),
                loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
                agentAccessPolicyOperations: library.operations, credentialMutations: mutations)
            model.isLocked = false
            model.hasManagementSession = true
            var messages: [String] = []
            for language in ["en", "zh-Hans"] {
                model.languageMode = language
                XCTAssertTrue(model.reloadCredentials())
                XCTAssertEqual(model.credentials.map(\.id), [credential.id])
                XCTAssertFalse(model.agentAccessPolicyNeedsRecovery)
                let message = try XCTUnwrap(model.errorMessage)
                XCTAssertTrue(message.contains(credential.name))
                XCTAssertFalse(message.contains("synthetic-private-value"))
                messages.append(message)
            }
            XCTAssertNotEqual(messages[0], messages[1])
            XCTAssertTrue(messages[0].contains("Credential management remains available"))
            XCTAssertTrue(messages[0].contains("Agent access stays off"))
        }
    }
}
