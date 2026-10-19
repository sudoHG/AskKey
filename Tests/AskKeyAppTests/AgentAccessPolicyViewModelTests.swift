import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class AgentAccessPolicyViewModelTests: AskKeyAppTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private let legacyKeys = [
        "readApprovalAuthenticationEnabled", "timedAllowanceEnabled", "defaultTimedAllowanceMinutes",
    ]

    override func setUp() {
        super.setUp()
        suite = "AskKey.policy.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testRevokedOwnerPauseShowsUnsavedStateAndResumeRefusesBeforeFurtherAuthentication() async throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        var authentications = 0
        let model = makeModel(library, authenticate: { authentications += 1; return .allow })
        model.languageMode = "en"
        try library.vault.setAgentAccessPolicyOwnership(true, validateOwnership: { false })
        let delivery = try library.vault.fileDeliveryManager.get().materialize(credentialID: "synthetic", bytes: Data("synthetic".utf8))
        await model.pauseAgentAccess()
        XCTAssertEqual(authentications, 1)
        XCTAssertTrue(model.isAgentAccessPaused)
        XCTAssertTrue(model.agentAccessPauseNotPersisted)
        XCTAssertTrue(try XCTUnwrap(model.agentAccessPolicyNotice).contains("No policy change was written"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.url.path))
        await model.resumeAgentAccess()
        XCTAssertEqual(authentications, 1)
        XCTAssertTrue(try XCTUnwrap(model.errorMessage).contains("has stopped serving"))
        XCTAssertTrue(try XCTUnwrap(model.errorMessage).contains("paused here"))
    }

    func testUnlockedPolicyAccessRejectionShowsSpecificLocalizedGuidance() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let model = makeModel(library)
        library.keys.loadFailure = AppKeyStoreError.policyReadAccessDenied
        XCTAssertThrowsError(try library.vault.brokerCredentialCatalog())
        model.refreshAgentAccessPauseState()
        model.languageMode = "en"
        let english = try XCTUnwrap(model.agentAccessPolicyNotice)
        XCTAssertTrue(english.contains("keychain is unlocked"))
        XCTAssertTrue(english.contains("access control in Keychain Access"))
        XCTAssertFalse(english.contains("Allow Keychain access"))
        model.languageMode = "zh-Hans"
        let chinese = try XCTUnwrap(model.agentAccessPolicyNotice)
        XCTAssertNotEqual(english, chinese)
        XCTAssertTrue(chinese.contains("Agent "))
    }

    func testOwnershipRevocationKeepsBrokerRetryVisibleAfterTheErrorIsDismissed() async throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let model = makeModel(library)
        model.languageMode = "en"
        let shown = expectation(description: "Revocation reported on the main actor")
        try library.vault.setAgentAccessPolicyOwnership(true, validateOwnership: { false }, onRevocation: {
            error in Task { @MainActor in
                model.presentBrokerOwnershipRevocation(error)
                shown.fulfill()
            }
        })
        XCTAssertThrowsError(try library.vault.brokerCredentialCatalog())
        await fulfillment(of: [shown], timeout: 2)
        model.refreshAgentAccessPauseState()
        XCTAssertTrue(model.isAgentAccessPaused)
        XCTAssertTrue(model.brokerRecoveryAvailable)
        let failure = try XCTUnwrap(model.brokerFailureMessage)
        XCTAssertTrue(failure.contains("socket ownership could not be verified"))
        model.errorMessage = nil
        model.refreshAgentAccessPauseState()
        XCTAssertEqual(model.brokerFailureMessage, failure)
        XCTAssertTrue(model.brokerRecoveryAvailable)
        var retries = 0
        model.retryBrokerStart = { retries += 1 }
        model.retryBrokerRecovery()
        XCTAssertEqual(retries, 1)
    }

    func testNonOwnerTighteningRefreshesLocalSettingsAndTheUnsavedNotice() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        try library.vault.updateReadApprovalAuthentication(false, using: .allow)
        let saved = library.keys.policy
        let model = makeModel(library)
        model.languageMode = "en"
        try library.vault.setAgentAccessPolicyOwnership(false)
        XCTAssertFalse(model.setReadApprovalAuthentication(true))
        model.setTimedAllowance(enabled: false, minutes: 15)
        XCTAssertTrue(model.readApprovalAuthenticationEnabled)
        XCTAssertFalse(model.timedAllowanceEnabled)
        XCTAssertEqual(model.defaultTimedAllowanceMinutes, 15)
        XCTAssertTrue(model.isAgentAccessPaused)
        XCTAssertTrue(try XCTUnwrap(model.agentAccessPolicyNotice).contains("could not save"))
        XCTAssertEqual(library.keys.policy, saved)
    }

    func testLegacyDefaultsCannotOverrideAuthenticatedPolicy() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        try library.vault.updateTimedAllowance(enabled: false, minutes: 60)
        setLegacyDefaults()
        let model = makeModel(library)

        // Construction itself never applies the unauthenticated opt-out.
        XCTAssertTrue(model.readApprovalAuthenticationEnabled)
        model.refreshAgentAccessPauseState()
        XCTAssertTrue(model.readApprovalAuthenticationEnabled)
        XCTAssertFalse(model.timedAllowanceEnabled)
        XCTAssertEqual(model.defaultTimedAllowanceMinutes, 60)
        for key in legacyKeys { XCTAssertNil(defaults.object(forKey: key)) }
    }

    func testEmptyLibraryDefaultPolicyAllowsLegacyDefaultsRemoval() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        setLegacyDefaults()
        let model = makeModel(library)
        model.refreshAgentAccessPauseState()
        XCTAssertEqual(model.agentAccessPolicy, .defaults)
        XCTAssertFalse(model.agentAccessPolicyNeedsRecovery)
        XCTAssertNil(model.agentAccessPolicyNotice)
        for key in legacyKeys { XCTAssertNil(defaults.object(forKey: key)) }
    }

    func testRefreshBeforeRuntimeOpenDoesNotPresentAnErrorOrRemoveLegacySettings() {
        setLegacyDefaults()
        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false }, accessRecords: .empty,
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            agentAccessPolicyOperations: .init(
                load: { throw VaultError.vaultLocked },
                setReadAuthentication: { _, _ in throw VaultError.vaultLocked },
                setTimedAllowance: { _, _ in throw VaultError.vaultLocked }
            ),
            credentialMutations: .readOnly { ([], [], [], false) }
        )
        model.refreshAgentAccessPauseState()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.readApprovalAuthenticationEnabled)
        XCTAssertNil(model.agentAccessPolicyNotice)
        for key in legacyKeys { XCTAssertNotNil(defaults.object(forKey: key)) }
        // Writes still surface the locked-vault error and retain memory.
        XCTAssertFalse(model.setReadApprovalAuthentication(false, using: .allow))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.readApprovalAuthenticationEnabled)
    }

    func testFailClosedOpenExposesNoticeAndKeepsLegacyDefaultsUntilResume() async throws {
        let library = try recoveringLibrary()
        defer { try? library.close() }
        setLegacyDefaults()
        let model = makeModel(library)
        model.refreshAgentAccessPauseState()

        XCTAssertTrue(model.isAgentAccessPaused)
        XCTAssertEqual(model.agentAccessPolicy, .failClosed)
        XCTAssertTrue(model.agentAccessPolicyNeedsRecovery)
        XCTAssertNotNil(model.agentAccessPolicyNotice)
        for key in legacyKeys { XCTAssertNotNil(defaults.object(forKey: key)) }
        await model.resumeAgentAccess()
        XCTAssertEqual(model.agentAccessPolicy, .defaults)
        XCTAssertFalse(model.isAgentAccessPaused)
        XCTAssertNil(model.agentAccessPolicyNotice)
        for key in legacyKeys { XCTAssertNil(defaults.object(forKey: key)) }
        try library.reopen()
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .defaults, needsRecovery: false))
    }

    func testCancelledResumeKeepsNoticeAndDoesNotWrite() async throws {
        let library = try recoveringLibrary()
        defer { try? library.close() }
        let model = makeModel(library, authenticate: { nil })
        model.refreshAgentAccessPauseState()
        await model.resumeAgentAccess()
        XCTAssertEqual(model.agentAccessPolicy, .failClosed)
        XCTAssertNotNil(model.agentAccessPolicyNotice)
        XCTAssertNil(library.keys.policy)
    }

    func testRecoveryRejectsSettingsAndKeepsNotice() throws {
        let library = try recoveringLibrary()
        defer { try? library.close() }
        let model = makeModel(library)
        model.refreshAgentAccessPauseState()
        XCTAssertFalse(model.setReadApprovalAuthentication(false, using: .allow))
        model.setTimedAllowance(enabled: true, minutes: 120)
        XCTAssertEqual(model.agentAccessPolicy, .failClosed)
        XCTAssertNotNil(model.agentAccessPolicyNotice)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(library.keys.policy)
    }

    func testFailedSettingsWriteKeepsSettingsButPausesAndShowsError() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let model = makeModel(library)
        model.refreshAgentAccessPauseState()
        library.keys.saveFailure = AppPolicySaveFailure()
        var pausedDefaults = AgentAccessPolicy.defaults
        pausedDefaults.paused = true

        XCTAssertFalse(model.setReadApprovalAuthentication(false, using: .allow))
        XCTAssertEqual(model.agentAccessPolicy, pausedDefaults)
        XCTAssertTrue(model.isAgentAccessPaused)
        XCTAssertTrue(model.agentAccessPauseNotPersisted)
        XCTAssertNotNil(model.errorMessage)
        model.errorMessage = nil
        model.setTimedAllowance(enabled: false, minutes: 120)
        XCTAssertEqual(model.agentAccessPolicy, pausedDefaults)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try library.vault.agentAccessPolicyState().policy, pausedDefaults)
    }

    func testFailedResumeWriteKeepsNoticeAndShowsError() async throws {
        let library = try recoveringLibrary()
        defer { try? library.close() }
        let model = makeModel(library)
        model.refreshAgentAccessPauseState()
        library.keys.saveFailure = AppPolicySaveFailure()
        await model.resumeAgentAccess()
        XCTAssertEqual(model.agentAccessPolicy, .failClosed)
        XCTAssertNotNil(model.agentAccessPolicyNotice)
        XCTAssertNotNil(model.errorMessage)
    }

    func testFailedPauseSaveShowsRestartWarningAndKeepsUIReallyPaused() async throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        defaults.set("en", forKey: "languageMode")
        let model = makeModel(library)
        model.refreshAgentAccessPauseState()
        library.keys.saveFailure = AppPolicySaveFailure()
        await model.pauseAgentAccess()
        XCTAssertTrue(model.isAgentAccessPaused)
        XCTAssertTrue(try library.vault.isAgentAccessPaused())
        XCTAssertTrue(try XCTUnwrap(model.errorMessage).contains("may be lost when Ask Key restarts"))
        XCTAssertFalse(model.agentAccessPolicyNeedsRecovery)
        XCTAssertTrue(model.agentAccessPauseNotPersisted)
        model.errorMessage = nil
        XCTAssertTrue(try XCTUnwrap(model.agentAccessPolicyNotice).contains("may be lost when Ask Key restarts"))
        try library.reopen()
        model.refreshAgentAccessPauseState()
        XCTAssertTrue(model.isAgentAccessPaused)
        XCTAssertNotNil(model.agentAccessPolicyNotice)
        library.keys.saveFailure = nil
        try library.reopen()
        model.refreshAgentAccessPauseState()
        XCTAssertTrue(model.isAgentAccessPaused)
        XCTAssertFalse(model.agentAccessPauseNotPersisted)
        XCTAssertNil(model.agentAccessPolicyNotice)
    }

    func testUnknownSettingsPersistenceShowsPersistentUnsavedPause() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        defaults.set("en", forKey: "languageMode")
        let model = makeModel(library)
        model.refreshAgentAccessPauseState()
        library.keys.saveFailure = AppKeyStoreError.policyPersistenceUnknown
        XCTAssertFalse(model.setReadApprovalAuthentication(false, using: .allow))
        XCTAssertTrue(model.isAgentAccessPaused)
        XCTAssertTrue(model.agentAccessPauseNotPersisted)
        XCTAssertTrue(try XCTUnwrap(model.errorMessage).contains("saved policy is unknown"))
        model.errorMessage = nil
        XCTAssertTrue(try XCTUnwrap(model.agentAccessPolicyNotice).contains("agent access settings"))
        XCTAssertTrue(try XCTUnwrap(model.agentAccessPolicyNotice).contains("saved policy is unknown"))
    }

    func testPolicyConflictNoticeNamesItemAndGivesRecoveryStepsInBothLanguages() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        library.keys.loadFailure = AppKeyStoreError.conflictingItem(.agentAccessPolicy)
        try library.reopen()
        let model = makeModel(library)
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        model.languageMode = "en"
        model.refreshAgentAccessPauseState()
        let english = try XCTUnwrap(model.agentAccessPolicyNotice)
        XCTAssertTrue(english.contains("agent-access-policy"))
        XCTAssertTrue(english.contains("Keychain Access"))
        XCTAssertTrue(model.isAgentAccessPaused)
        XCTAssertTrue(model.agentAccessPolicyNeedsRecovery)
        model.languageMode = "zh-Hans"
        let chinese = try XCTUnwrap(model.agentAccessPolicyNotice)
        XCTAssertTrue(chinese.contains("\u{94a5}\u{5319}\u{4e32}\u{8bbf}\u{95ee}"))
        XCTAssertTrue(chinese.contains("agent-access-policy"))
        XCTAssertNotEqual(chinese, english)
    }

    func testRestoredValidPolicyDoesNotClearRecoveryNotice() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let saved = library.keys.policy
        library.keys.policy = nil
        try library.reopen()
        library.keys.policy = saved
        try library.reopen()
        let model = makeModel(library)
        model.refreshAgentAccessPauseState()
        XCTAssertTrue(model.isAgentAccessPaused)
        XCTAssertTrue(model.agentAccessPolicyNeedsRecovery)
        XCTAssertNotNil(model.agentAccessPolicyNotice)
    }

    func testSuccessfulEraseRefreshesActualGateAndClearsPendingNotice() async throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        defaults.set("en", forKey: "languageMode")
        let model = makeModel(library)
        library.keys.saveFailure = AppPolicySaveFailure()
        await model.pauseAgentAccess()
        XCTAssertTrue(model.agentAccessPauseNotPersisted)
        model.isLocked = false
        model.hasManagementSession = true
        try library.vault.beginManagementSession(using: .allow)
        let erased = await model.eraseLocalLibrary(confirmation: "ERASE")
        XCTAssertTrue(erased)
        XCTAssertEqual(model.isAgentAccessPaused, try library.vault.isAgentAccessPaused())
        XCTAssertFalse(model.agentAccessPauseNotPersisted)
        XCTAssertFalse(model.agentAccessPolicyNeedsRecovery)
        XCTAssertNil(model.agentAccessPolicyNotice)
    }

    func testFailedOpenRefreshesPausedGateInUI() async throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let model = makeModel(library)
        model.refreshAgentAccessPauseState()
        XCTAssertFalse(model.isAgentAccessPaused)
        library.keys.appKey = nil
        model.isLocked = true
        await model.unlockForManagement()
        XCTAssertTrue(model.isAgentAccessPaused)
        XCTAssertTrue(model.agentAccessPolicyNeedsRecovery)
        XCTAssertNotNil(model.errorMessage)
    }

    func testFailedEraseShowsGatePauseWhenPersistedPolicyIsActive() async throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let coordinator = library.vault.makeLocalEraseCoordinator(
            journal: FileLocalVaultEraseJournalStore(url: library.directory.appendingPathComponent("erase.journal")),
            deleteEncryptedData: { throw AppPolicySaveFailure() },
            deleteLocalKey: { XCTFail("Keys must survive failed data deletion") }
        )
        defaults.set("en", forKey: "languageMode")
        let model = makeModel(library, erase: { try coordinator.erase(confirmation: $0, language: $1, using: $2) })
        model.refreshAgentAccessPauseState()
        model.isLocked = false
        model.hasManagementSession = true
        let erased = await model.eraseLocalLibrary(confirmation: "ERASE")
        XCTAssertFalse(erased)
        XCTAssertFalse(model.agentAccessPolicy.paused)
        XCTAssertTrue(model.isAgentAccessPaused)
        XCTAssertNotNil(model.errorMessage)
    }

    func testLockRefreshesActualGateInsteadOfSavedPolicy() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let model = makeModel(library)
        model.refreshAgentAccessPauseState()
        library.vault.lock()
        model.lock()
        XCTAssertFalse(model.agentAccessPolicy.paused)
        XCTAssertTrue(model.isAgentAccessPaused)
    }

    func testEraseJournalFailureStillShowsPausedAfterPolicySnapshotWasRemoved() async throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let coordinator = library.vault.makeLocalEraseCoordinator(journal: PolicyEraseJournalClearFailure())
        defaults.set("en", forKey: "languageMode")
        let model = makeModel(library, erase: { try coordinator.erase(confirmation: $0, language: $1, using: $2) })
        model.refreshAgentAccessPauseState()
        model.isLocked = false
        model.hasManagementSession = true
        let erased = await model.eraseLocalLibrary(confirmation: "ERASE")
        XCTAssertFalse(erased)
        XCTAssertNil(library.keys.appKey)
        XCTAssertNil(library.keys.policy)
        XCTAssertThrowsError(try library.vault.agentAccessPolicyState())
        XCTAssertTrue(model.isAgentAccessPaused)
        XCTAssertNotNil(model.errorMessage)
    }

    func testLegacyDefaultsAreDeletedOnceAndRemainIgnoredAfterReintroduction() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        setLegacyDefaults()
        let model = makeModel(library)
        model.refreshAgentAccessPauseState()
        for key in legacyKeys { XCTAssertNil(defaults.object(forKey: key)) }
        setLegacyDefaults()
        model.refreshAgentAccessPauseState()
        for key in legacyKeys { XCTAssertNotNil(defaults.object(forKey: key)) }
        XCTAssertEqual(model.agentAccessPolicy, .defaults)
        let reopenedPreferences = AppPreferences(defaults: defaults)
        reopenedPreferences.removeLegacyAgentAccessSettings()
        for key in legacyKeys { XCTAssertNotNil(defaults.object(forKey: key)) }
    }

    func testSessionTimeoutLoadsOnlyPositiveValuesAtMostFiveMinutes() {
        XCTAssertEqual(AppPreferences(defaults: defaults).sessionTimeoutSeconds, 300)
        for invalid in [-1.0, 0, 301, Double.infinity, Double.nan, Double(Int.max)] {
            defaults.set(invalid, forKey: "sessionTimeoutSeconds")
            XCTAssertEqual(AppPreferences(defaults: defaults).sessionTimeoutSeconds, 300)
        }
        for valid in [0.01, 1, 60, 300] {
            defaults.set(valid, forKey: "sessionTimeoutSeconds")
            XCTAssertEqual(AppPreferences(defaults: defaults).sessionTimeoutSeconds, valid)
        }
    }

    func testSettingsOfferOnlyVaultOwnedMinutes() {
        XCTAssertEqual(FrozenTimedAllowanceSettingsPresentation.choices, Vault.allowedTimedAllowanceMinutes)
        for invalid in [Int.min, -1, 0, 45, 121, Int.max] {
            XCTAssertEqual(FrozenTimedAllowanceSettingsPresentation.sanitized(invalid), 30)
            XCTAssertEqual(FrozenTimedAllowanceSettingsPresentation.menuChoices(current: invalid), Vault.allowedTimedAllowanceMinutes)
        }
    }

    func testNoticeIsLocalizedAndRemainsExposedAfterLanguageChange() throws {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        let library = try recoveringLibrary()
        defer { try? library.close() }
        let model = makeModel(library)
        model.refreshAgentAccessPauseState()
        model.languageMode = "en"
        let english = try XCTUnwrap(model.agentAccessPolicyNotice)
        XCTAssertTrue(english.contains("missing or changed outside Ask Key"))
        model.languageMode = "zh-Hans"
        let chinese = try XCTUnwrap(model.agentAccessPolicyNotice)
        XCTAssertFalse(chinese.isEmpty)
        XCTAssertNotEqual(chinese, english)
        XCTAssertEqual(chinese, AppLanguage.localized(english, language: "zh-Hans"))
        XCTAssertTrue(model.agentAccessPolicyNeedsRecovery)
    }

    private func setLegacyDefaults() {
        defaults.set(false, forKey: "readApprovalAuthenticationEnabled")
        defaults.set(true, forKey: "timedAllowanceEnabled")
        defaults.set(120, forKey: "defaultTimedAllowanceMinutes")
    }

    private func recoveringLibrary() throws -> AgentAccessPolicyTestLibrary {
        let library = try AgentAccessPolicyTestLibrary()
        _ = try library.vault.createTextCredential(.init(
            name: "SYNTHETIC", value: "synthetic-value", permission: .allowed
        ), using: .allow)
        library.keys.policy = nil
        try library.reopen()
        return library
    }

    private func makeModel(
        _ library: AgentAccessPolicyTestLibrary,
        authenticate: @escaping () -> ManagementAuthenticator? = { .allow },
        erase: ((String, LocalVaultEraseLanguage, ManagementAuthenticator) throws -> Void)? = nil
    ) -> VaultViewModel {
        VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: erase ?? { try library.vault.eraseLocalLibrary(confirmation: $0, language: $1, using: $2) },
            authenticateLocalErase: { _ in .allow },
            unlockVault: { try library.vault.unlock() },
            beginManagementSession: { try library.vault.beginManagementSession(using: $0) },
            authenticateDeviceOwner: { _ in authenticate() },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            agentAccessPolicyOperations: library.operations,
            pauseAgentAccess: { try library.vault.pauseAgentAccess(using: $0) },
            resumeAgentAccess: { try library.vault.resumeAgentAccess(using: $0) },
            credentialMutations: .readOnly { ([], [], [], false) }
        )
    }

}

private struct AppPolicySaveFailure: Error {}

private final class PolicyEraseJournalClearFailure: LocalVaultEraseJournalStore {
    private var state: LocalVaultEraseState?
    func load() throws -> LocalVaultEraseState? { state }
    func save(_ state: LocalVaultEraseState) throws { self.state = state }
    func clear() throws { throw AppPolicySaveFailure() }
}
