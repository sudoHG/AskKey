import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class AgentAccessPolicyMessageTests: AskKeyAppTestCase {
    func testSaveFailureCopyDistinguishesOperationAndWriteOutcomeInBothLanguages() throws {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        for operation in [AgentAccessPolicySaveFailure.Operation.pause, .settings, .resume] {
            let unchanged = AgentAccessPolicySaveFailure(operation, cause: AppKeyStoreError.conflictingKey)
            let unknown = AgentAccessPolicySaveFailure(operation, cause: AppKeyStoreError.policyPersistenceUnknown)
            AppLanguage.current = "en"
            let unchangedEnglish = UserFacingCopy.message(for: unchanged)
            let unknownEnglish = UserFacingCopy.message(for: unknown)
            XCTAssertTrue(unchangedEnglish.contains("No policy change was written"))
            XCTAssertFalse(unknownEnglish.contains("No policy change was written"))
            XCTAssertTrue(unknownEnglish.contains("could not verify"))
            if operation == .settings {
                XCTAssertTrue(unchangedEnglish.contains("agent access settings"))
                XCTAssertTrue(unknownEnglish.contains("agent access settings"))
            } else if operation == .resume {
                XCTAssertTrue(unchangedEnglish.contains("Resume Agent Access"))
                XCTAssertTrue(unknownEnglish.contains("Resume Agent Access"))
            }
            AppLanguage.current = "zh-Hans"
            let unchangedChinese = UserFacingCopy.message(for: unchanged)
            let unknownChinese = UserFacingCopy.message(for: unknown)
            XCTAssertNotEqual(unchangedChinese, unchangedEnglish)
            XCTAssertNotEqual(unknownChinese, unknownEnglish)
            XCTAssertTrue(unchangedChinese.contains("\u{672a}\u{5199}\u{5165}"))
            XCTAssertTrue(unknownChinese.contains("\u{65e0}\u{6cd5}\u{786e}\u{8ba4}"))
            XCTAssertNotEqual(unchangedChinese, unknownChinese)
        }
    }

    func testEveryConflictNamesItsItemAndManualRecoveryWithoutGenericKeychainError() {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        for kind in [AppKeychainItemKind.vaultKey, .pendingKey, .legacyKey, .agentAccessPolicy] {
            let error = AppKeyStoreError.conflictingItem(kind)
            AppLanguage.current = "en"
            let english = UserFacingCopy.message(for: error)
            XCTAssertEqual(english, kind.conflictMessage)
            XCTAssertTrue(english.contains("Keychain Access"))
            XCTAssertTrue(english.contains("login.keychain-db"))
            if kind != .agentAccessPolicy { XCTAssertTrue(english.contains("original")) }
            AppLanguage.current = "zh-Hans"
            let chinese = UserFacingCopy.message(for: error)
            XCTAssertNotEqual(chinese, english)
            XCTAssertTrue(chinese.contains("\u{94a5}\u{5319}\u{4e32}\u{8bbf}\u{95ee}"))
            let failure = AgentAccessPolicySaveFailure(.resume, cause: error)
            let message = UserFacingCopy.message(for: failure)
            XCTAssertTrue(message.contains(chinese))
            XCTAssertTrue(message.contains("\u{672a}\u{5199}\u{5165}"))
        }
    }
}
