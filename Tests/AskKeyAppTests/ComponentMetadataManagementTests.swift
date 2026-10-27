import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class ComponentMetadataManagementTests: AskKeyAppTestCase {
    func testUnavailableComponentsNeverClaimNamesCountsOrDelivery() {
        let credential = ManagedTextCredential(id: "synthetic-unavailable", name: "Synthetic", value: nil,
            usageInstructions: "", privateNotes: nil, groupName: nil, environmentVariable: nil,
            permission: .ask, expiresAt: nil, payloadKind: .bundle, originalFilename: nil,
            byteSize: nil, contentDigest: nil, fileBytes: nil,
            components: [.init(name: "UNAVAILABLE_NAME", value: nil)], componentDetailsAvailable: false)
        XCTAssertTrue(credential.components.isEmpty)
        ApprovalCardFixtures.withLanguages { language in
            let presentation = CredentialListPresentation(credential: credential)
            let expected = language == "en" ? "Component details are unavailable" : "组件详情不可用" // i18n-literal: Assert unavailable details in Simplified Chinese.
            XCTAssertEqual(presentation.secondaryLine, expected)
            XCTAssertEqual(CredentialListPresentation.componentCountTitle(credential), expected)
            XCTAssertEqual(presentation.monogram, "?")
            XCTAssertFalse(presentation.secondaryLine.contains("UNAVAILABLE_NAME"))
        }
    }

    func testEmptyIntegrityAndStorageMessagesHaveNoEmptyCredentialListAndDeletionAdviceIsExplicit() {
        ApprovalCardFixtures.withLanguages { language in
            let integrity = UserFacingCopy.message(for: ComponentMetadataUpgradeError(reason: .integrity, credentialNames: []))
            XCTAssertFalse(integrity.contains("Affected credentials:"))
            XCTAssertFalse(integrity.contains("%@"))
            let backfill = UserFacingCopy.message(for: ComponentMetadataUpgradeError(reason: .backfill, credentialNames: ["Synthetic API"]))
            let storage = UserFacingCopy.message(for: ComponentMetadataUpgradeError(reason: .storage, credentialNames: []))
            if language == "en" {
                XCTAssertTrue(backfill.contains("permanently from the Recycle Bin"))
                XCTAssertTrue(storage.contains("Check available disk space"))
                XCTAssertTrue(storage.contains("Do not delete credentials"))
            } else {
                XCTAssertTrue(backfill.contains("回收站中永久删除")) // i18n-literal: Match the product Recycle Bin label.
                XCTAssertTrue(storage.contains("不要通过删除凭证")) // i18n-literal: Storage failures never blame credentials.
            }
        }
    }

    func testMetadataFailureBlocksResumeBeforeAuthenticationOrPolicyMutation() async throws {
        let issue = ComponentMetadataUpgradeError(reason: .backfill, credentialNames: ["Synthetic API"])
        let model = try NoticeLayoutFixtures.Model(language: "en", state: .management, recovery: false, broker: false, metadataIssue: issue)
        defer { model.close() }
        await model.vault.resumeAgentAccess()
        XCTAssertEqual(model.vault.componentMetadataFailure, issue)
        XCTAssertFalse(model.vault.agentAccessPolicyNeedsRecovery)
        XCTAssertEqual(model.vault.errorMessage, UserFacingCopy.message(for: issue))
        model.vault.hasManagementSession = false
        XCTAssertFalse(model.vault.agentAccessPolicyNotice?.contains("Synthetic API") ?? true,
            "Locked metadata notices never expose credential display names")
    }

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
                authenticateDeviceOwner: { _ in .authenticated(.allow) }, preferences: AppPreferences(defaults: defaults),
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
