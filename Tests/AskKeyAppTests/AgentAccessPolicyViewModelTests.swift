import Foundation
import GRDB
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
        XCTAssertNil(try library.store.configValue(key: Vault.agentAccessPolicyConfigKey))
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
        XCTAssertNil(try library.store.configValue(key: Vault.agentAccessPolicyConfigKey))
    }

    func testFailedSettingsWriteKeepsPreviousMemoryAndShowsError() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let model = makeModel(library)
        model.refreshAgentAccessPauseState()
        try rejectWrites(library)

        XCTAssertFalse(model.setReadApprovalAuthentication(false, using: .allow))
        XCTAssertEqual(model.agentAccessPolicy, .defaults)
        XCTAssertNotNil(model.errorMessage)
        model.errorMessage = nil
        model.setTimedAllowance(enabled: false, minutes: 120)
        XCTAssertEqual(model.agentAccessPolicy, .defaults)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try library.vault.agentAccessPolicyState().policy, .defaults)
    }

    func testFailedResumeWriteKeepsNoticeAndShowsError() async throws {
        let library = try recoveringLibrary()
        defer { try? library.close() }
        let model = makeModel(library)
        model.refreshAgentAccessPauseState()
        try rejectWrites(library)
        await model.resumeAgentAccess()
        XCTAssertEqual(model.agentAccessPolicy, .failClosed)
        XCTAssertNotNil(model.agentAccessPolicyNotice)
        XCTAssertNotNil(model.errorMessage)
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
        try library.store.setConfigValue(key: Vault.agentAccessPolicyConfigKey, value: nil)
        try library.reopen()
        return library
    }

    private func makeModel(
        _ library: AgentAccessPolicyTestLibrary,
        authenticate: @escaping () -> ManagementAuthenticator? = { .allow }
    ) -> VaultViewModel {
        VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            authenticateDeviceOwner: { _ in authenticate() },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            agentAccessPolicyOperations: library.operations,
            pauseAgentAccess: { try library.vault.pauseAgentAccess(using: $0) },
            resumeAgentAccess: { try library.vault.resumeAgentAccess(using: $0) },
            credentialMutations: .readOnly { ([], [], [], false) }
        )
    }

    private func rejectWrites(_ library: AgentAccessPolicyTestLibrary) throws {
        try library.store.db.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_app_policy_write BEFORE INSERT ON config
                WHEN NEW.key = 'agent_access_policy'
                BEGIN SELECT RAISE(ABORT, 'synthetic policy write failure'); END
                """)
        }
    }
}
