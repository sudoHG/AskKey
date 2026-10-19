import Security
import XCTest
@testable import AskKeyVault

final class AgentAccessPolicyReadFailureTests: XCTestCase {
    func testUnlockedPolicyReadRejectionsHaveSpecificGuidanceWithoutRecovery() throws {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecInteractionRequired, errSecNoAccessForItem] {
            let error = AppBoundKeyStore.policyReadError(AppKeyStoreError.securityFailure(status), keychainUnlocked: true)
            XCTAssertEqual(error as? AppKeyStoreError, .policyReadAccessDenied)
            let library = try AgentAccessPolicyLibrary()
            defer { try? library.close() }
            library.keys.policyLoadFailure = error
            XCTAssertThrowsError(try library.vault.brokerCredentialCatalog())
            let state = try library.vault.agentAccessPolicyState()
            XCTAssertTrue(state.isPaused)
            XCTAssertFalse(state.needsRecovery)
            XCTAssertEqual(state.readFailure, .accessDenied)
            XCTAssertTrue(state.readFailure?.messageKey.contains("Keychain Access") == true)
            library.keys.policyLoadFailure = nil
            XCTAssertNoThrow(try library.vault.brokerCredentialCatalog())
        }
    }

    func testLockedKeychainAndOtherReadErrorsRemainTransientUnavailable() {
        for (status, unlocked) in [(errSecAuthFailed, false), (errSecInteractionNotAllowed, false), (errSecNotAvailable, true)] {
            let original = AppKeyStoreError.securityFailure(status)
            XCTAssertEqual(AppBoundKeyStore.policyReadError(original, keychainUnlocked: unlocked) as? AppKeyStoreError, original)
        }
    }
}
