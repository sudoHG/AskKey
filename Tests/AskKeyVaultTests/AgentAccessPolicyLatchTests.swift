import Foundation
import XCTest
@testable import AskKeyVault

final class AgentAccessPolicyLatchTests: XCTestCase {
    func testFailedPauseSurvivesReopenAndRetryClearsOnlyUnsavedNotice() throws {
        let library = try makeLibrary()
        let oldActive = library.keys.policy
        library.keys.policySaveFailure = SyntheticPolicyFailure()
        XCTAssertThrowsError(try library.vault.pauseAgentAccess(using: .allow))
        try library.reopen()
        try assertPaused(library, pending: true)
        XCTAssertEqual(library.keys.policy, oldActive)

        library.keys.policySaveFailure = nil
        try library.reopen()
        try assertPaused(library, pending: false)
        XCTAssertTrue(try AgentAccessPolicyAuthentication.open(XCTUnwrap(library.keys.policy), using: library.key).paused)

        // Even after persistence, reopening cannot undo this process's intent.
        library.keys.policy = oldActive
        try library.reopen()
        try assertPaused(library, pending: false)
        XCTAssertThrowsError(try library.vault.resumeAgentAccess(using: .deny))
        try assertPaused(library, pending: false)
        try library.vault.resumeAgentAccess(using: .allow)
        try library.reopen()
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .defaults, needsRecovery: false))
    }

    func testRecoveryLatchSurvivesRestoredValidPolicyUntilAuthenticatedResume() throws {
        let library = try makeLibrary()
        try library.vault.updateReadApprovalAuthentication(false, using: .allow)
        try library.vault.updateTimedAllowance(enabled: true, minutes: 120)
        let oldActive = library.keys.policy
        library.keys.policy = nil
        try library.reopen()
        library.keys.policy = oldActive
        let writes = library.keys.policyWrites
        try library.reopen()
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .failClosed, needsRecovery: true))
        XCTAssertEqual(library.keys.policy, oldActive)
        XCTAssertEqual(library.keys.policyWrites, writes)
        XCTAssertThrowsError(try library.vault.resumeAgentAccess(using: .deny))
        try library.vault.resumeAgentAccess(using: .allow)
        try library.reopen()
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .defaults, needsRecovery: false))
    }

    func testUnsavedPauseNeverSignsMissingOrInvalidPolicyDuringRetry() throws {
        for replacement in [nil, Data("unauthenticated".utf8)] {
            let library = try makeLibrary()
            library.keys.policySaveFailure = SyntheticPolicyFailure()
            XCTAssertThrowsError(try library.vault.pauseAgentAccess(using: .allow))
            library.keys.policySaveFailure = nil
            library.keys.policy = replacement
            let writes = library.keys.policyWrites
            try library.reopen()
            try assertPaused(library, pending: true, recovery: true)
            XCTAssertEqual(library.keys.policy, replacement)
            XCTAssertEqual(library.keys.policyWrites, writes)
            try library.vault.resumeAgentAccess(using: .allow)
            XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .defaults, needsRecovery: false))
        }
    }

    func testUnknownPersistenceAfterSettingsOrResumeLatchesPause() throws {
        for operation in ["settings", "resume"] {
            let library = try makeLibrary()
            library.keys.policySaveFailure = AppKeyStoreError.policyPersistenceUnknown
            XCTAssertThrowsError(try {
                if operation == "settings" {
                    try library.vault.updateTimedAllowance(enabled: false, minutes: 120)
                } else {
                    try library.vault.resumeAgentAccess(using: .allow)
                }
            }()) {
                XCTAssertEqual(($0 as? AgentAccessPolicySaveFailure)?.operation, operation == "settings" ? .settings : .resume)
                XCTAssertEqual(($0 as? AgentAccessPolicySaveFailure)?.persistedStateIsUnknown, true)
            }
            try assertPaused(library, pending: true)
            try library.reopen()
            try assertPaused(library, pending: true)
            library.keys.policySaveFailure = nil
            try library.reopen()
            try assertPaused(library, pending: false)
        }
    }

    func testFailedPauseRetriesPersistenceAfterTransientReadRecovers() throws {
        let library = try makeLibrary()
        let savedPolicy = library.keys.policy
        library.keys.policySaveFailure = SyntheticPolicyFailure()
        XCTAssertThrowsError(try library.vault.pauseAgentAccess(using: .allow))
        library.keys.policySaveFailure = nil
        library.keys.policyLoadFailure = SyntheticPolicyFailure()
        let writes = library.keys.policyWrites

        try library.reopen()
        try assertPaused(library, pending: true)
        XCTAssertEqual(library.keys.policyWrites, writes)
        XCTAssertEqual(library.keys.policy, savedPolicy)
        library.keys.policyLoadFailure = nil
        try library.reopen()

        try assertPaused(library, pending: false)
        XCTAssertEqual(library.keys.policyWrites, writes + 1)
        XCTAssertTrue(try AgentAccessPolicyAuthentication.open(XCTUnwrap(library.keys.policy), using: library.key).paused)
        try library.vault.resumeAgentAccess(using: .allow)
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .defaults, needsRecovery: false))
    }

    func testPreflightConflictKeepsSettingsAndResumePausedWithoutClaimingAWrite() throws {
        for operation in ["settings", "resume"] {
            let library = try makeLibrary()
            let saved = library.keys.policy
            let writes = library.keys.policyWrites
            library.keys.policySaveFailure = AppKeyStoreError.conflictingItem(.agentAccessPolicy)
            XCTAssertThrowsError(try {
                if operation == "settings" {
                    try library.vault.updateReadApprovalAuthentication(false, using: .allow)
                } else {
                    try library.vault.resumeAgentAccess(using: .allow)
                }
            }()) {
                let failure = $0 as? AgentAccessPolicySaveFailure
                XCTAssertEqual(failure?.operation, operation == "settings" ? .settings : .resume)
                XCTAssertEqual(failure?.persistedStateIsUnknown, false)
                XCTAssertEqual(failure?.keychainConflict, .agentAccessPolicy)
            }
            try assertPaused(library, pending: true)
            XCTAssertEqual(library.keys.policy, saved)
            XCTAssertEqual(library.keys.policyWrites, writes)
            XCTAssertNotNil(try library.vault.agentAccessPolicyState().saveFailure)
        }
    }

    func testPolicyReadConflictIsExposedWithFailClosedStateAndNoWrites() throws {
        let library = try makeLibrary()
        let writes = library.keys.policyWrites
        library.keys.policyLoadFailure = AppKeyStoreError.conflictingItem(.agentAccessPolicy)
        try library.reopen()
        let state = try library.vault.agentAccessPolicyState()
        XCTAssertEqual(state.policy, .failClosed)
        XCTAssertTrue(state.needsRecovery)
        XCTAssertEqual(state.keychainConflict, .agentAccessPolicy)
        XCTAssertEqual(library.keys.policyWrites, writes)
    }

    func testExplicitPauseRetryAlsoMarksPersistenceWithoutClearingIntent() throws {
        let library = try makeLibrary()
        let oldActive = library.keys.policy
        library.keys.policySaveFailure = SyntheticPolicyFailure()
        XCTAssertThrowsError(try library.vault.pauseAgentAccess(using: .allow))
        library.keys.policySaveFailure = nil
        try library.vault.pauseAgentAccess(using: .allow)
        try assertPaused(library, pending: false)
        library.keys.policy = oldActive
        try library.reopen()
        try assertPaused(library, pending: false)
    }

    func testSuccessfulAuthenticatedEraseResetsLatchesForNewLibrary() throws {
        let library = try makeLibrary()
        library.keys.policySaveFailure = SyntheticPolicyFailure()
        XCTAssertThrowsError(try library.vault.pauseAgentAccess(using: .allow))
        library.keys.policy = nil
        try library.reopen()
        try assertPaused(library, pending: true, recovery: true)
        try library.vault.beginManagementSession(using: .allow)
        try library.vault.eraseLocalLibrary(confirmation: "ERASE", language: .english, using: .allow)
        library.keys.policySaveFailure = nil
        try library.reopen()
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .defaults, needsRecovery: false))
    }

    private func makeLibrary() throws -> AgentAccessPolicyLibrary {
        let library = try AgentAccessPolicyLibrary()
        addTeardownBlock { try library.close() }
        return library
    }

    private func assertPaused(_ library: AgentAccessPolicyLibrary, pending: Bool, recovery: Bool = false) throws {
        let state = try library.vault.agentAccessPolicyState()
        XCTAssertTrue(state.isPaused)
        XCTAssertTrue(state.policy.paused)
        XCTAssertEqual(state.pauseNotPersisted, pending)
        XCTAssertEqual(state.needsRecovery, recovery)
        XCTAssertThrowsError(try library.vault.brokerCredentialCatalog())
    }
}
