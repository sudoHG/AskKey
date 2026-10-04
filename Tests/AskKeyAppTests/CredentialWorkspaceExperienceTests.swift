import AppKit
import CoreServices
import LocalAuthentication
import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class CredentialWorkspaceExperienceTests: AppLanguageExperienceTestSupport {
    func testCredentialWorkspaceHasNoFolderAssociationAndGroupsOwnCreationActions() throws {
        let source = try CredentialManagementSource.read(
            from: repoRoot(),
            relative: "Sources/AskKeyAppKit/Views/CredentialManagementView.swift"
        )

        XCTAssertFalse(source.contains("folderAssociations"))
        XCTAssertFalse(source.contains("associateFolder"))
        XCTAssertFalse(source.contains("linkFolder"))
        XCTAssertTrue(source.contains("New group"))
        XCTAssertTrue(source.contains("Import from File"))
        XCTAssertFalse(source.contains("从文件导入到本组"))
        XCTAssertTrue(source.contains("CredentialComponentDraft(isOptional: true)"))
        XCTAssertTrue(source.contains("Authenticate and Replace"))
        XCTAssertTrue(source.contains("Recycle Bin"))
        let viewModelSource = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "Sources/AskKeyAppKit/VaultViewModel+Credentials.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(viewModelSource.contains("loadCredentialWorkspaceImpl"))
        let defaultAdapterSource = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/AskKeyAppKit/VaultViewModel.swift"),
            encoding: .utf8
        )
        let workspaceSource = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "Sources/AskKeyAppKit/CredentialWorkspaceMutations.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(workspaceSource.contains("purgeRecycledTextCredentials"))
        XCTAssertTrue(defaultAdapterSource.contains("credentialMutations.loadWorkspace"))
        XCTAssertFalse(defaultAdapterSource.contains("loadCredentialWorkspace:"))
        let appSource = try AskKeyAppSource.read(from: repoRoot())
        XCTAssertTrue(appSource.contains("purgeExpiredRecycledCredentials"))
    }

    func testAgentClientsUsePlainLanguageAutomaticConnection() throws {
        let source = try CredentialManagementSource.read(
            from: repoRoot(),
            relative: "Sources/AskKeyAppKit/Views/CredentialManagementView.swift"
        )
        XCTAssertTrue(source.contains("AgentOnboardingView()"))
        XCTAssertFalse(source.contains("预览用户级配置差异"))
        XCTAssertFalse(source.contains("先看差异"))
        XCTAssertFalse(source.contains("Review the diff"))
        XCTAssertFalse(source.contains("reason: \"Connect \\(client.rawValue) to Ask Key\""))
        XCTAssertFalse(source.contains("setString("))
        XCTAssertFalse(source.contains("Local Ask Key connection is healthy"))
        XCTAssertFalse(source.contains("{\"command\""))
        let onboardingSource = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "Sources/AskKeyAppKit/Views/AgentOnboardingView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(onboardingSource.contains("onboarding.appear()"))
        XCTAssertTrue(onboardingSource.contains("presentation.actionTitle(expanded: expanded)"))
        XCTAssertTrue(onboardingSource.contains("subtitle: FrozenSettingsContract.agentAccessSubtitle"))
        XCTAssertFalse(onboardingSource.contains("{\"command\""))
        let connectorSource = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "Sources/AskKeyAppKit/AgentClientConnector.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(connectorSource.contains("redactedCursorDiff"))
        XCTAssertFalse(connectorSource.contains("\"command\""))

    }
}
