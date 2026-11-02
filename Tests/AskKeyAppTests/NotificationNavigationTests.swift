import AppKit
import UserNotifications
import XCTest
import AskKeyBroker
import AskKeyVault
@testable import AskKeyAppKit

@MainActor
final class NotificationNavigationTests: AskKeyAppTestCase {
    private let id = "00000000-0000-0000-0000-000000000212"
    private let otherID = "00000000-0000-0000-0000-000000000213"

    func testCredentialClickWaitsForSuccessfulUnlockAndReadsNoLockedMetadata() async throws {
        let fixture = try makeFixture()
        let navigation = ManagementNavigation()
        navigation.section = .named("SYNTHETIC previous group")
        navigation.route = .credentialDetail(otherID)
        let prompts = ApprovalPromptRecorder()
        let observer = prompts.observe()
        defer { NotificationCenter.default.removeObserver(observer) }
        var opens = 0
        click(.credential(id), navigation: navigation) { opens += 1 }
        navigation.applyPendingNotification(to: fixture.vault)

        XCTAssertEqual(opens, 1)
        XCTAssertEqual(navigation.section, .all)
        XCTAssertEqual(navigation.route, .library)
        XCTAssertEqual(fixture.loads, 0)
        XCTAssertEqual(fixture.authentications, 0)
        XCTAssertEqual(prompts.count, 0)
        XCTAssertTrue(fixture.vault.isLocked)

        fixture.authenticationResult = .cancelled
        await fixture.vault.unlockForManagement()
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(navigation.route, .library)
        XCTAssertEqual(fixture.loads, 0)

        fixture.authenticationResult = .authenticated(.allow)
        await fixture.vault.unlockForManagement()
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(navigation.route, .credentialDetail(id))
        XCTAssertEqual(navigation.section, .all)
        XCTAssertNil(fixture.vault.revealedCredential)
        XCTAssertGreaterThan(fixture.loads, 0)
    }

    func testIdleExpiredManagementSessionAlsoDefersSelection() throws {
        let fixture = try makeFixture()
        fixture.vault.isLocked = false
        let navigation = ManagementNavigation()
        click(.credential(id), navigation: navigation)
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(navigation.route, .library)
        XCTAssertEqual(fixture.loads, 0)
    }

    func testUnlockedClickSelectsCredentialOutsideThePreviousGroup() throws {
        let fixture = try makeFixture()
        fixture.vault.isLocked = false
        fixture.vault.hasManagementSession = true
        let navigation = ManagementNavigation()
        navigation.section = .ungrouped
        click(.credential(id), navigation: navigation)
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(navigation.route, .credentialDetail(id))
        XCTAssertEqual(navigation.section, .all)
    }

    func testPendingRequestsSelectsQueueAndExpiredQueueFallsBack() throws {
        let fixture = try makeFixture()
        let navigation = ManagementNavigation()
        let prompts = ApprovalPromptRecorder()
        let observer = prompts.observe()
        defer { NotificationCenter.default.removeObserver(observer) }
        fixture.vault.isLocked = false
        fixture.vault.hasManagementSession = true
        fixture.vault.pendingApprovalCount = 1
        click(.pendingRequests, navigation: navigation)
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(navigation.route, .pendingRequests)

        fixture.vault.pendingApprovalCount = 0
        click(.pendingRequests, navigation: navigation)
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(navigation.route, .library)
        XCTAssertEqual(prompts.count, 0, "Unlocked clicks keep navigating within management")
    }

    func testLockedPendingClickOpensApprovalOnceAfterManagementOpensWithoutUnlocking() async throws {
        let fixture = try makeFixture()
        let navigation = ManagementNavigation()
        try enqueueApproval()
        XCTAssertEqual(fixture.vault.pendingApprovalCount, 0, "The deferred count has not caught up")
        fixture.failLoading = true
        let prompts = ApprovalPromptRecorder()
        let observer = prompts.observe()
        defer { NotificationCenter.default.removeObserver(observer) }
        var opens = 0
        click(.pendingRequests, navigation: navigation) {
            opens += 1
            XCTAssertEqual(prompts.count, 0)
        }
        navigation.applyPendingNotification(to: fixture.vault)
        navigation.applyPendingNotification(to: fixture.vault)

        XCTAssertEqual(opens, 1)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts.receivedOnlyUntargetedPrompts)
        XCTAssertEqual(navigation.route, .library)
        XCTAssertEqual(navigation.section, .all)
        XCTAssertTrue(fixture.vault.isLocked)
        XCTAssertFalse(fixture.vault.hasManagementSession)
        XCTAssertEqual(fixture.authentications, 0)
        XCTAssertEqual(fixture.loads, 0)

        fixture.failLoading = false
        await fixture.vault.unlockForManagement()
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(navigation.route, .library, "Unlock must not replay the consumed reminder")
        XCTAssertEqual(prompts.count, 1)
    }

    func testPendingClickWithExpiredManagementSessionAlsoOpensApproval() throws {
        let fixture = try makeFixture()
        fixture.vault.isLocked = false
        try enqueueApproval()
        let navigation = ManagementNavigation()
        let prompts = ApprovalPromptRecorder()
        let observer = prompts.observe()
        defer { NotificationCenter.default.removeObserver(observer) }

        click(.pendingRequests, navigation: navigation)
        navigation.applyPendingNotification(to: fixture.vault)

        XCTAssertEqual(prompts.count, 1)
        XCTAssertFalse(fixture.vault.hasManagementSession)
        XCTAssertEqual(fixture.loads, 0)
        XCTAssertEqual(fixture.authentications, 0)
    }

    func testExpiredLockedPendingClickFallsBackAndIsNotReplayedForLaterRequests() throws {
        let fixture = try makeFixture()
        let navigation = ManagementNavigation()
        let prompts = ApprovalPromptRecorder()
        let observer = prompts.observe()
        defer { NotificationCenter.default.removeObserver(observer) }
        fixture.vault.pendingApprovalCount = 1
        click(.pendingRequests, navigation: navigation)
        navigation.applyPendingNotification(to: fixture.vault)
        try enqueueApproval()
        navigation.applyPendingNotification(to: fixture.vault)
        fixture.vault.isLocked = false
        fixture.vault.hasManagementSession = true
        navigation.applyPendingNotification(to: fixture.vault)

        XCTAssertEqual(prompts.count, 0)
        XCTAssertEqual(navigation.route, .library)
        XCTAssertEqual(fixture.loads, 0)
    }

    func testLockedPendingClickPreservesWorkAndDropsDestination() throws {
        let fixture = try makeFixture()
        try enqueueApproval()
        let navigation = ManagementNavigation()
        navigation.interaction.searchText = "SYNTHETIC unfinished search"
        let prompts = ApprovalPromptRecorder()
        let observer = prompts.observe()
        defer { NotificationCenter.default.removeObserver(observer) }
        var opens = 0
        click(.pendingRequests, navigation: navigation) { opens += 1 }
        navigation.applyPendingNotification(to: fixture.vault)

        XCTAssertEqual(opens, 1)
        XCTAssertEqual(navigation.interaction.searchText, "SYNTHETIC unfinished search")
        XCTAssertEqual(navigation.notificationRevision, 0)
        navigation.interaction.reset()
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(prompts.count, 0)
        XCTAssertEqual(navigation.route, .library)
        XCTAssertEqual(fixture.loads, 0)
    }

    func testWorkStartedBeforeLockedPendingClickIsConsumedPreventsApproval() throws {
        let fixture = try makeFixture()
        try enqueueApproval()
        let navigation = ManagementNavigation()
        let prompts = ApprovalPromptRecorder()
        let observer = prompts.observe()
        defer { NotificationCenter.default.removeObserver(observer) }
        click(.pendingRequests, navigation: navigation)
        navigation.route = .editor(template: .custom, credentialID: nil)
        navigation.interaction.searchText = "SYNTHETIC unfinished work"
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(navigation.route, .editor(template: .custom, credentialID: nil))
        navigation.route = .library
        navigation.interaction.reset()
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(prompts.count, 0)
        XCTAssertEqual(fixture.loads, 0)
    }

    func testLockedPendingClickPreservesRememberedPagesThroughUnlock() throws {
        let fixture = try makeFixture()
        try enqueueApproval()
        let prompts = ApprovalPromptRecorder()
        let observer = prompts.observe()
        defer { NotificationCenter.default.removeObserver(observer) }
        for page in [CredentialWorkspaceRoute.settings, .agentAccess,
                     .editor(template: .custom, credentialID: nil)] {
            fixture.vault.isLocked = true
            fixture.vault.hasManagementSession = false
            let navigation = ManagementNavigation()
            navigation.route = page
            let before = prompts.count
            var opens = 0
            click(.pendingRequests, navigation: navigation) { opens += 1 }
            XCTAssertEqual(navigation.route, page)
            navigation.applyPendingNotification(to: fixture.vault)
            navigation.applyPendingNotification(to: fixture.vault)
            XCTAssertEqual(prompts.count, before + 1)
            XCTAssertEqual(opens, 1)
            XCTAssertEqual(navigation.route, page)
            XCTAssertEqual(fixture.authentications, 0)
            XCTAssertEqual(fixture.loads, 0)
            fixture.vault.isLocked = false
            fixture.vault.hasManagementSession = true
            navigation.applyPendingNotification(to: fixture.vault)
            XCTAssertEqual(navigation.route, page)
            XCTAssertEqual(prompts.count, before + 1)
        }
    }

    func testLockedPendingClickReplacesDeferredCredentialWithoutReplayingItAfterUnlock() async throws {
        let fixture = try makeFixture()
        try enqueueApproval()
        let navigation = ManagementNavigation()
        let prompts = ApprovalPromptRecorder()
        let observer = prompts.observe()
        defer { NotificationCenter.default.removeObserver(observer) }
        click(.credential(id), navigation: navigation)
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(navigation.route, .library)
        XCTAssertEqual(prompts.count, 0)
        click(.pendingRequests, navigation: navigation)
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(fixture.loads, 0)
        XCTAssertEqual(fixture.authentications, 0)
        await fixture.vault.unlockForManagement()
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(navigation.route, .library)
        XCTAssertEqual(prompts.count, 1)
    }

    func testLockedWriteFailureMainRouteDoesNotOpenApprovalOrClearError() throws {
        let fixture = try makeFixture()
        try enqueueApproval()
        let navigation = ManagementNavigation()
        let prompts = ApprovalPromptRecorder()
        let observer = prompts.observe()
        defer { NotificationCenter.default.removeObserver(observer) }
        fixture.vault.errorMessage = "SYNTHETIC write failure"
        var opens = 0
        click(.main, navigation: navigation) { opens += 1 }
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(prompts.count, 0)
        XCTAssertEqual(fixture.vault.errorMessage, "SYNTHETIC write failure")
        XCTAssertEqual(fixture.loads, 0)
        XCTAssertEqual(fixture.authentications, 0)
    }

    func testDeletedRecycledUnknownAndUnreadableTargetsFallBack() throws {
        let fixture = try makeFixture()
        let navigation = ManagementNavigation()
        fixture.vault.isLocked = false
        fixture.vault.hasManagementSession = true
        fixture.recycled = fixture.credentials
        fixture.credentials = []
        for target in [NotificationRoute.credential(id), .credential(otherID), .main] {
            click(target, navigation: navigation)
            navigation.applyPendingNotification(to: fixture.vault)
            XCTAssertEqual(navigation.route, .library)
        }
        fixture.failLoading = true
        click(.pendingRequests, navigation: navigation)
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(navigation.route, .library)
    }

    func testTargetIsRevalidatedAfterUnlockAndLatestClickWins() async throws {
        let fixture = try makeFixture()
        let navigation = ManagementNavigation()
        click(.credential(otherID), navigation: navigation)
        click(.credential(id), navigation: navigation)
        await fixture.vault.unlockForManagement()
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(navigation.route, .credentialDetail(id))
        XCTAssertEqual(navigation.notificationRevision, 2)

        fixture.vault.isLocked = true
        fixture.vault.hasManagementSession = false
        click(.credential(id), navigation: navigation)
        fixture.credentials = []
        await fixture.vault.unlockForManagement()
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(navigation.route, .library)
    }

    func testDismissAndUnrecognizedActionsDoNotOpenOrReplaceTheTarget() throws {
        let navigation = ManagementNavigation()
        for action in [UNNotificationDismissActionIdentifier, "unknown-action"] {
            navigation.handleNotificationResponse(
                actionIdentifier: action, userInfo: NotificationRoute.credential(id).userInfo,
                entryState: .locked,
                openManagement: { XCTFail("Only a click should open management") }
            )
        }
        XCTAssertEqual(navigation.notificationRevision, 0)
        XCTAssertEqual(navigation.route, .library)
    }

    func testOpenEditorImportAndNestedConfirmationPagesOnlyBringWindowForward() throws {
        let fixture = try makeFixture()
        for page in [CredentialWorkspaceRoute.editor(template: .custom, credentialID: id),
                     .fileImport, .templateChooser, .settings] {
            let navigation = ManagementNavigation()
            navigation.route = page
            navigation.section = .named("SYNTHETIC draft group")
            var opens = 0
            click(.credential(otherID), navigation: navigation, entryState: .management) { opens += 1 }
            XCTAssertEqual(opens, 1)
            XCTAssertEqual(navigation.route, page)
            XCTAssertEqual(navigation.section, .named("SYNTHETIC draft group"))
            XCTAssertEqual(navigation.notificationRevision, 0, "The existing view keeps its identity")
            navigation.route = .library
            fixture.vault.isLocked = false
            fixture.vault.hasManagementSession = true
            navigation.applyPendingNotification(to: fixture.vault)
            XCTAssertEqual(fixture.loads, 0, "The blocked destination was dropped")
        }
    }

    func testOpenDeleteConfirmationIsPreservedAndDestinationIsDropped() throws {
        let fixture = try makeFixture()
        try enqueueApproval()
        fixture.vault.isLocked = false
        fixture.vault.hasManagementSession = true
        let navigation = ManagementNavigation()
        let prompts = ApprovalPromptRecorder()
        let observer = prompts.observe()
        defer { NotificationCenter.default.removeObserver(observer) }
        navigation.route = .credentialDetail(id)
        navigation.interaction.deletingCredential = fixture.credentials[0]
        var opens = 0
        click(.pendingRequests, navigation: navigation, entryState: .management) { opens += 1 }
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(navigation.route, .credentialDetail(id))
        XCTAssertEqual(navigation.interaction.deletingCredential?.id, id)
        XCTAssertEqual(navigation.notificationRevision, 0)
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(prompts.count, 0)
        navigation.interaction.deletingCredential = nil
        fixture.vault.pendingApprovalCount = 1
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(prompts.count, 0)
        XCTAssertEqual(navigation.route, .credentialDetail(id), "Closing the confirmation must not resume the click")
        XCTAssertEqual(fixture.loads, 0)
    }

    func testGroupPermanentDeleteAndSearchStateAlsoPreventNavigation() {
        let protections: [(ManagementInteractionState) -> Void] = [
            { (state: ManagementInteractionState) in state.deletingGroupName = "SYNTHETIC" },
            { $0.permanentlyDeletingCredentialID = self.id },
            { $0.showingNewGroup = true; $0.newGroupName = "SYNTHETIC draft" },
            { $0.searchText = "SYNTHETIC query" },
        ]
        for protect in protections {
            let navigation = ManagementNavigation()
            protect(navigation.interaction)
            click(.pendingRequests, navigation: navigation, entryState: .management)
            XCTAssertEqual(navigation.notificationRevision, 0)
            XCTAssertTrue(navigation.interaction.hasWorkInProgress)
        }
    }

    func testOnboardingInProgressAndFirstRunKeepTheirCurrentPage() {
        for entry in [SettingsEntryState.onboarding, .empty, .management] {
            let navigation = ManagementNavigation()
            let page: CredentialWorkspaceRoute = entry == .management ? .agentAccess : .library
            navigation.route = page
            var opens = 0
            click(.credential(id), navigation: navigation, entryState: entry) { opens += 1 }
            XCTAssertEqual(opens, 1)
            XCTAssertEqual(navigation.route, page)
            XCTAssertEqual(navigation.notificationRevision, 0)
        }
    }

    func testOpeningAnEditorBeforeUnlockDropsTheDeferredDestination() async throws {
        let fixture = try makeFixture()
        let navigation = ManagementNavigation()
        click(.credential(id), navigation: navigation)
        navigation.route = .editor(template: .custom, credentialID: nil)
        await fixture.vault.unlockForManagement()
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(navigation.route, .editor(template: .custom, credentialID: nil))
        navigation.route = .library
        navigation.applyPendingNotification(to: fixture.vault)
        XCTAssertEqual(navigation.route, .library)
    }

    func testRealRootPreservesConfirmationAndExpandedAgentOnboarding() async throws {
        let fixture = try makeFixture()
        fixture.vault.isLocked = false
        fixture.vault.hasManagementSession = true
        let previous = AppRuntimeState.configuration
        AppRuntimeState.configuration = .init(makeViewModel: { fixture.vault })
        defer { AppRuntimeState.configuration = previous }
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let navigation = delegate.managementNavigation
        navigation.route = .credentialDetail(id)
        delegate.ensureManagementWindow()
        let window = try XCTUnwrap(delegate.managementWindow)
        defer { window.close() }
        await layoutHiddenWindow(window)
        navigation.interaction.deletingCredential = fixture.credentials[0]
        click(.pendingRequests, navigation: navigation, entryState: .management) {
            delegate.ensureManagementWindow()
        }
        await layoutHiddenWindow(window)
        XCTAssertEqual(navigation.route, .credentialDetail(id))
        XCTAssertEqual(navigation.interaction.deletingCredential?.id, id)
        navigation.interaction.deletingCredential = nil
        navigation.route = .agentAccess
        await layoutHiddenWindow(window)
        fixture.vault.onboarding.explain(.codex)
        click(.credential(id), navigation: navigation, entryState: .management) {
            delegate.ensureManagementWindow()
        }
        await layoutHiddenWindow(window)
        XCTAssertEqual(navigation.route, .agentAccess)
        XCTAssertEqual(fixture.vault.onboarding.expandedClient, .codex)
        XCTAssertEqual(fixture.vault.onboarding.session(for: .codex).attempt.phase, .explanation)
        XCTAssertEqual(navigation.notificationRevision, 0)
        XCTAssertFalse(window.isVisible)
    }

    func testColdClickBeforeWindowCreationSurvivesUntilTheRootCanConsumeIt() async throws {
        let fixture = try makeFixture()
        let previous = AppRuntimeState.configuration
        AppRuntimeState.configuration = .init(makeViewModel: { fixture.vault })
        defer { AppRuntimeState.configuration = previous }
        _ = NSApplication.shared
        let delegate = AppDelegate()
        XCTAssertNil(delegate.managementWindow)
        click(.credential(id), navigation: delegate.managementNavigation) {
            delegate.ensureManagementWindow()
        }
        let window = try XCTUnwrap(delegate.managementWindow)
        defer { window.close() }
        await layoutHiddenWindow(window)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(delegate.managementNavigation.route, .library)
        await fixture.vault.unlockForManagement()
        await layoutHiddenWindow(window)
        XCTAssertEqual(delegate.managementNavigation.route, .credentialDetail(id))
        XCTAssertFalse(window.isVisible)
    }

    func testRealLockedRootConsumesColdAndWarmPendingClicksWithoutUnlocking() async throws {
        let fixture = try makeFixture()
        try enqueueApproval()
        let previous = AppRuntimeState.configuration
        AppRuntimeState.configuration = .init(makeViewModel: { fixture.vault })
        defer { AppRuntimeState.configuration = previous }
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let prompts = ApprovalPromptRecorder()
        let observer = prompts.observe()
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertNil(delegate.managementWindow)
        click(.pendingRequests, navigation: delegate.managementNavigation) {
            delegate.ensureManagementWindow()
        }
        let window = try XCTUnwrap(delegate.managementWindow)
        defer { window.close() }
        await layoutHiddenWindow(window)
        XCTAssertEqual(prompts.count, 1)

        click(.pendingRequests, navigation: delegate.managementNavigation) {
            delegate.ensureManagementWindow()
        }
        await layoutHiddenWindow(window)
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(fixture.vault.isLocked)
        XCTAssertFalse(fixture.vault.hasManagementSession)
        XCTAssertEqual(fixture.authentications, 0)
        XCTAssertEqual(fixture.loads, 0)
        XCTAssertEqual(delegate.managementNavigation.route, .library)
        XCTAssertFalse(window.isVisible)
    }

    private func layoutHiddenWindow(_ window: NSWindow) async {
        for _ in 0..<10 {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func click(
        _ route: NotificationRoute, navigation: ManagementNavigation,
        entryState: SettingsEntryState = .locked,
        open: () -> Void = {}
    ) {
        navigation.handleNotificationResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: route.userInfo, entryState: entryState, openManagement: open
        )
    }

    private func makeFixture() throws -> NotificationNavigationFixture {
        let suite = "NotificationNavigationTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "hasCompletedOnboarding")
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return NotificationNavigationFixture(id: id, defaults: defaults)
    }

    private func enqueueApproval() throws {
        let queue = Vault.shared.approvalRequests
        let ticket = try queue.submit(.init(
            operationID: "synthetic-notification-\(UUID())", credentialID: id, targetID: id,
            operation: .read, payloadDigest: String(repeating: "a", count: 64)
        ), trustedCredentialDeadline: .none)
        addTeardownBlock { _ = try queue.cancel(requestID: ticket.requestID, capability: ticket.capability) }
    }
}

@MainActor
private final class ApprovalPromptRecorder {
    var count = 0
    var receivedOnlyUntargetedPrompts = true

    func observe() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .presentNextAgentApproval, object: nil, queue: .main
        ) { [self] note in
            MainActor.assumeIsolated {
                count += 1
                receivedOnlyUntargetedPrompts = receivedOnlyUntargetedPrompts && note.object == nil
            }
        }
    }
}

@MainActor
private final class NotificationNavigationFixture {
    var credentials: [ManagedTextCredential]
    var recycled: [ManagedTextCredential] = []
    var loads = 0
    var authentications = 0
    var failLoading = false
    var authenticationResult: ManagementAuthenticationResult = .authenticated(.allow)
    let defaults: UserDefaults
    private let policy = AgentAccessPolicyTestState()

    lazy var vault = VaultViewModel(
        runtimeFileCleanupFailures: { false }, accessRecords: .empty,
        unlockVault: {}, beginManagementSession: { _ in },
        authenticateDeviceOwner: { [unowned self] _ in
            authentications += 1
            return authenticationResult
        },
        preferences: AppPreferences(defaults: defaults),
        loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
        agentAccessPolicyOperations: policy.operations,
        credentialMutations: CredentialWorkspaceMutations.readOnly { [unowned self] in
            loads += 1
            if failLoading { throw CocoaError(.fileReadCorruptFile) }
            return (credentials, recycled, ["SYNTHETIC target group"], false)
        }.counting { [unowned self] in credentials.count }
    )

    init(id: String, defaults: UserDefaults) {
        self.defaults = defaults
        credentials = [.init(
            id: id, name: "SYNTHETIC notification target", value: nil,
            usageInstructions: "SYNTHETIC", privateNotes: nil,
            groupName: "SYNTHETIC target group", environmentVariable: nil,
            permission: .ask, expiresAt: nil, payloadKind: .bundle,
            originalFilename: nil, byteSize: nil, contentDigest: nil,
            fileBytes: nil, components: [.init(name: "SYNTHETIC_FIELD", value: nil)]
        )]
    }
}
