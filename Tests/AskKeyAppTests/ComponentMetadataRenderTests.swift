import AppKit
import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

/// Production management windows remain hidden; no alert or screen capture.
@MainActor
final class ComponentMetadataRenderTests: AskKeyAppTestCase {
    func testMetadataFailureManagementWindowsInBothLanguages() throws {
        try ApprovalCardFixtures.withLanguages { language in
            for variant in ["backfill", "integrity-empty", "storage", "settings-unavailable"] {
                let reason: ComponentMetadataUpgradeError.Reason = variant == "integrity-empty" ? .integrity : variant == "storage" ? .storage : .backfill
                let issue = ComponentMetadataUpgradeError(reason: reason, credentialNames: reason == .backfill ? ["Synthetic API"] : [])
                let model = try NoticeLayoutFixtures.Model(language: language, state: .management,
                    recovery: false, broker: false, metadataIssue: issue)
                defer { model.close() }
                XCTAssertTrue(model.vault.reloadCredentials())
                model.vault.errorMessage = nil
                let content = CredentialManagementView(initialRoute: variant == "settings-unavailable" ? .settings : .library, previewMode: true)
                    .environment(model.vault).environment(\.locale, model.vault.appLocale)
                let window = ManagementWindowConfiguration.makeWindow(rootView: content)
                window.appearance = NSAppearance(named: .aqua)
                defer { window.close() }
                let view = try XCTUnwrap(window.contentView)
                for _ in 0..<8 {
                    window.layoutIfNeeded()
                    view.layoutSubtreeIfNeeded()
                    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
                }
                XCTAssertFalse(window.isVisible)
                XCTAssertEqual(model.vault.componentMetadataFailure, issue)
                XCTAssertNil(model.vault.errorMessage, "Render the persistent management notice, never a native alert")
                XCTAssertFalse(model.vault.agentAccessPolicyNeedsRecovery)
                let frame = try XCTUnwrap(view.superview)
                _ = try NoticeLayoutFixtures.render(frame)
                try NoticeLayoutFixtures.export(NoticeLayoutFixtures.render(frame), name: "\(language)-metadata-\(variant)")
                XCTAssertFalse(window.isVisible)
            }
        }
    }
}
