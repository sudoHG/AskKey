import AppKit
import LocalAuthentication
import SwiftUI
import AskKeyBroker
import AskKeyVault

/// Owns the subscription without making a cleanup worker wait for the UI thread.
final class FileCleanupFailureObservation {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(
        center: NotificationCenter = .default,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        self.center = center
        token = center.addObserver(
            forName: .askKeyFileDeliveryCleanupFailed,
            object: nil,
            queue: nil
        ) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { handler() }
            } else {
                Task { @MainActor in handler() }
            }
        }
    }

    deinit { center.removeObserver(token) }
}

enum SettingsEntryState: Equatable {
    case onboarding
    case empty
    case locked
    case management
}

@Observable
@MainActor
package final class VaultViewModel {
    package var isLocked = true
    var onboarding = AgentOnboardingCoordinator()
    var errorMessage: String?
    /// Set by the popover to hand the "new credential" action over to the manager
    /// window: a `MenuBarExtra(.window)` popover closes as soon as a sheet takes
    /// key focus, so the add form can't live there. The manager consumes and
    /// clears this on appear (window opening) or on change (window already open).
    var pendingAddSecret = false
    var credentials: [ManagedTextCredential] = []
    var recycledCredentials: [ManagedTextCredential] = []
    var storedCredentialGroups: [String] = []
    var credentialAccessRecords: [CredentialAccessEvent] = []
    package var hasManagementSession = false
    var isAgentAccessPaused = false
    var revealedCredential: ManagedTextCredential?
    var pendingApprovalCount = 0
    var brokerRecoveryAvailable = false
    var brokerFailureMessage: String?
    var retryBrokerStart: (() -> Void)?
    var pendingApprovalRequests: [BrokerApprovalOperationRequest] {
        pendingApprovals.map(\.request)
    }
    var pendingApprovals: [BrokerPendingApproval] {
        // Register the observable queue signal even when a nonempty list does
        // not render the count, so cancelled rows cannot remain on screen.
        _ = pendingApprovalCount
        return Vault.shared.approvalRequests.pendingRequests()
    }
    var onboardingCredentialCount = 0
    var onboardingLaunchAtLoginEnabled = true
    /// The first credential saved before onboarding completes, for the welcome page.
    var onboardingSavedCredential: OnboardingSavedCredential?

    var sessionTimeoutSeconds: Double {
        get {
            preferences.sessionTimeoutSeconds
        }
        set {
            preferences.sessionTimeoutSeconds = newValue
            if !isLocked { renewSession() }
        }
    }

    var launchAtLogin: Bool {
        get { loginItem.isEnabled }
        set {
            do {
                try loginItem.setEnabled(newValue)
            } catch {
                presentError(error)
            }
        }
    }

    var clipboardClearSeconds: Double { preferences.clipboardClearSeconds }

    // Stored (not computed) so @Observable tracks it and the UI re-renders on change.
    var appearanceMode: String = "system" {
        didSet { preferences.appearanceMode = appearanceMode }
    }

    var languageMode: String = "system" {
        didSet {
            preferences.languageMode = languageMode
            AppLanguage.apply(mode: languageMode)
        }
    }

    func presentError(_ error: Error) {
        if KeychainFailureDisposition.classify(error) == .cancelled {
            errorMessage = nil
            return
        }
        errorMessage = UserFacingCopy.message(for: error)
    }

    var hasCompletedOnboarding = false {
        didSet { preferences.hasCompletedOnboarding = hasCompletedOnboarding }
    }

    var defaultTimedAllowanceMinutes: Int {
        get { preferences.defaultTimedAllowanceMinutes }
        set {
            preferences.defaultTimedAllowanceMinutes = newValue
            updateTimedAllowance(newValue)
        }
    }

    var readApprovalAuthenticationEnabled: Bool {
        get {
            access(keyPath: \.readApprovalAuthenticationEnabled)
            return preferences.readApprovalAuthenticationEnabled
        }
        set {
            withMutation(keyPath: \.readApprovalAuthenticationEnabled) {
                preferences.readApprovalAuthenticationEnabled = newValue
                updateReadAuthentication(newValue)
            }
        }
    }

    var timedAllowanceEnabled: Bool {
        get { preferences.timedAllowanceEnabled }
        set { preferences.timedAllowanceEnabled = newValue }
    }

    var brandName: String {
        AppLanguage.brandName(language: AppLanguage.resolve(mode: languageMode))
    }

    var appLocale: Locale {
        Locale(identifier: AppLanguage.resolve(mode: languageMode))
    }

    package var showsLockedWorkbench = false

    var settingsEntryState: SettingsEntryState {
        if showsLockedWorkbench { return .locked }
        if !hasCompletedOnboarding { return .onboarding }
        if onboardingCredentialCount == 0 && !hasManagementSession { return .empty }
        if isLocked || !hasManagementSession { return .locked }
        return .management
    }

    var hotkeyShortcutID: String {
        get { preferences.hotkeyShortcutID }
        set { preferences.hotkeyShortcutID = newValue }
    }

    var colorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private let preferences: AppPreferences
    @ObservationIgnored private var fileCleanupFailureObservation: FileCleanupFailureObservation?
    private let loginItem: LoginItemController
    private let updateTimedAllowance: (Int) -> Void
    private let updateReadAuthentication: (Bool) -> Void
    private let managementSessionIdleLimit: TimeInterval
    private let sessionPolicy = SessionPolicy()
    private let managementSessionPolicy = SessionPolicy()
    let clipboard = ClipboardController()
    let accessRecords: CredentialAccessRecordMutations
    let authenticateCredentialAccessRecordClear: (@MainActor (String) async -> ManagementAuthenticator)?
    let eraseLocalLibraryImpl: (
        String, LocalVaultEraseLanguage, ManagementAuthenticator
    ) throws -> Void
    let authenticateLocalErase: (@MainActor (String) async -> ManagementAuthenticator)?
    let unlockVaultImpl: () throws -> Void
    let beginManagementSessionImpl: (ManagementAuthenticator) throws -> Void
    let beginOnboardingManagementSessionImpl: () throws -> Void
    let storedCredentialCountImpl: () throws -> Int
    let loadCredentialWorkspaceImpl: () throws -> (credentials: [ManagedTextCredential], recycled: [ManagedTextCredential], groups: [String], accessRecordWriteFailure: Bool)
    let credentialMutations: CredentialWorkspaceMutations
    private(set) var managementAuthorizationGeneration: UInt64 = 0
    let authenticateDeviceOwner: (@MainActor (ManagementAuthenticationPresentation) async -> ManagementAuthenticator?)?
    let isAgentAccessPausedImpl: () throws -> Bool
    let pauseAgentAccessImpl: (ManagementAuthenticator) throws -> Void
    let resumeAgentAccessImpl: (ManagementAuthenticator) throws -> Void

    init(
        runtimeFileCleanupFailures: () -> Bool = { Vault.shared.hasRuntimeFileCleanupFailures },
        accessRecords: CredentialAccessRecordMutations? = nil,
        authenticateCredentialAccessRecordClear: (@MainActor (String) async -> ManagementAuthenticator)? = nil,
        eraseLocalLibrary: @escaping (
            String, LocalVaultEraseLanguage, ManagementAuthenticator
        ) throws -> Void = {
            try Vault.shared.eraseLocalLibrary(confirmation: $0, language: $1, using: $2)
        },
        authenticateLocalErase: (@MainActor (String) async -> ManagementAuthenticator)? = nil,
        unlockVault: @escaping () throws -> Void = { try Vault.shared.unlock() },
        beginManagementSession: @escaping (ManagementAuthenticator) throws -> Void = {
            try Vault.shared.beginManagementSession(using: $0)
        },
        beginOnboardingManagementSession: @escaping () throws -> Void = {
            try Vault.shared.beginOnboardingCreation()
        },
        authenticateDeviceOwner: (@MainActor (ManagementAuthenticationPresentation) async -> ManagementAuthenticator?)? = nil,
        preferences: AppPreferences = AppPreferences(),
        loginItem: LoginItemController = LoginItemController(),
        managementSessionIdleLimit: TimeInterval = Vault.managementSessionIdleLimit,
        updateTimedAllowance: @escaping (Int) -> Void = { minutes in
            Vault.shared.updateDefaultTimedAllowanceMinutes(minutes)
        },
        updateReadAuthentication: @escaping (Bool) -> Void = { enabled in
            Vault.shared.approvalRequests.setReadAuthenticationEnabled(enabled)
        },
        isAgentAccessPaused: @escaping () throws -> Bool = {
            try Vault.shared.isAgentAccessPaused()
        },
        pauseAgentAccess: @escaping (ManagementAuthenticator) throws -> Void = {
            try Vault.shared.pauseAgentAccess(using: $0)
        },
        resumeAgentAccess: @escaping (ManagementAuthenticator) throws -> Void = {
            try Vault.shared.resumeAgentAccess(using: $0)
        },
        credentialMutations: CredentialWorkspaceMutations = .live
    ) {
        self.accessRecords = accessRecords ?? credentialMutations.accessRecords
        self.authenticateCredentialAccessRecordClear = authenticateCredentialAccessRecordClear
        eraseLocalLibraryImpl = eraseLocalLibrary
        self.authenticateLocalErase = authenticateLocalErase
        unlockVaultImpl = unlockVault
        beginManagementSessionImpl = beginManagementSession
        beginOnboardingManagementSessionImpl = beginOnboardingManagementSession
        storedCredentialCountImpl = credentialMutations.storedCredentialCount
        loadCredentialWorkspaceImpl = credentialMutations.loadWorkspace
        self.credentialMutations = credentialMutations
        self.authenticateDeviceOwner = authenticateDeviceOwner
        isAgentAccessPausedImpl = isAgentAccessPaused
        pauseAgentAccessImpl = pauseAgentAccess
        resumeAgentAccessImpl = resumeAgentAccess
        self.preferences = preferences
        self.loginItem = loginItem
        self.managementSessionIdleLimit = managementSessionIdleLimit
        self.updateTimedAllowance = updateTimedAllowance
        self.updateReadAuthentication = updateReadAuthentication
        appearanceMode = preferences.appearanceMode
        languageMode = preferences.languageMode
        hasCompletedOnboarding = preferences.hasCompletedOnboarding
        do {
            onboardingCredentialCount = try storedCredentialCountImpl()
        } catch {
            presentError(error)
        }
        AppLanguage.apply(mode: preferences.languageMode)
        updateReadAuthentication(preferences.readApprovalAuthenticationEnabled)
        fileCleanupFailureObservation = FileCleanupFailureObservation { [weak self] in
            self?.errorMessage = "Ask Key could not remove a temporary credential file. It will keep retrying."
        }
        if runtimeFileCleanupFailures() {
            errorMessage = "Ask Key could not remove a temporary credential file. It will keep retrying."
        }
        attachOnboardingRuntime()
    }

    func attachOnboardingRuntime() {
        onboarding.operations = AgentOnboardingRuntime.liveOperations(
            authenticate: { [weak self] in
                await self?.authenticateForOnboardingWrite() ?? .failed
            },
            revalidateWriteSession: { [weak self] in
                self?.hasManagementSession == true && self?.isLocked == false
            }
        )
    }

    func authenticateForOnboardingWrite() async -> AgentAuthenticationOutcome {
        if hasManagementSession {
            renewManagementSession()
            return .confirmed
        }
        guard let authenticator = await confirmDeviceOwner(reason: CredentialManagementCopy.manageReason) else {
            errorMessage = nil
            return .cancelled
        }
        do {
            try beginManagementSessionImpl(authenticator)
            hasManagementSession = true
            renewManagementSession()
            return .confirmed
        } catch {
            errorMessage = nil
            return .failed
        }
    }

    // MARK: - Lock / Unlock

    func unlock() {
        Task { [weak self] in
            await self?.unlockForManagement()
        }
    }

    func unlockForManagement() async {
        if hasManagementSession {
            renewManagementSession()
            renewSession()
            return
        }
        guard let authenticator = await confirmDeviceOwner(
            reason: CredentialManagementCopy.manageReason
        ) else { return }
        do {
            if isLocked {
                try unlockVaultImpl()
                isLocked = false
            }
            try beginManagementSessionImpl(authenticator)
            hasManagementSession = true
            showsLockedWorkbench = false
            reloadCredentials()
            renewManagementSession()
        } catch {
            switch KeychainFailureDisposition.classify(error) {
            case .cancelled:
                errorMessage = nil
            case .failed:
                errorMessage = appLocalized(
                    "Ask Key could not access the vault. Allow Keychain access, then try again."
                )
            case nil:
                presentError(error)
            }
        }
    }

    func completeOnboarding(enableLaunchAtLogin: Bool) {
        launchAtLogin = enableLaunchAtLogin
        hasCompletedOnboarding = true
        onboardingSavedCredential = nil
    }

    func recordOnboardingSave(name: String, permission: CredentialPermission) {
        guard !hasCompletedOnboarding else { return }
        onboardingSavedCredential = OnboardingSavedCredential(name: name, permission: permission)
    }

    /// First-run creation is the user's explicit action, but it is not an identity
    /// check. Existing vaults never take this path because onboarding is persisted.
    @discardableResult
    func beginOnboardingManagement() -> Bool {
        guard onboardingCredentialCount == 0 else { return false }
        do {
            if isLocked {
                try unlockVaultImpl()
                isLocked = false
            }
            try beginOnboardingManagementSessionImpl()
            hasManagementSession = false
            showsLockedWorkbench = false
            renewSession()
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func lock() {
        sessionPolicy.cancel()
        // Human management locking does not disable the App-owned Agent runtime.
        endManagementSession()
        isLocked = true
        showsLockedWorkbench = true
    }

    func endManagementSession() {
        // Closing/locking invalidates approvals still awaiting system auth too.
        // A later successful response must not recreate the closed session.
        managementAuthorizationGeneration &+= 1
        managementSessionPolicy.cancel()
        Vault.shared.endManagementSession()
        hasManagementSession = false
        credentials = []
        recycledCredentials = []
        storedCredentialGroups = []
        credentialAccessRecords = []
        revealedCredential = nil
    }

    func renewSession() {
        guard !isLocked, !hasManagementSession else { return }
        sessionPolicy.renew(timeout: sessionTimeoutSeconds) { [weak self] in
            guard let self, !hasManagementSession else { return }
            lock()
        }
    }

    func renewManagementSession() {
        guard hasManagementSession else { return }
        managementSessionPolicy.renew(timeout: managementSessionIdleLimit) { [weak self] in
            self?.endManagementSession()
        }
    }

    // MARK: - Data loading

    func refreshAgentAccessPauseState() {
        do {
            isAgentAccessPaused = try isAgentAccessPausedImpl()
        } catch {
            presentError(error)
        }
    }

    func presentBrokerRuntimeFailure(_ error: Error) {
        let failure = BrokerRuntimeFailure.userFacing(for: error)
        brokerFailureMessage = failure.message
        brokerRecoveryAvailable = failure.canRetry
        errorMessage = failure.message
    }

    func clearBrokerRuntimeFailure() {
        if errorMessage == brokerFailureMessage {
            errorMessage = nil
        }
        brokerFailureMessage = nil
        brokerRecoveryAvailable = false
    }

    func retryBrokerRecovery() {
        retryBrokerStart?()
    }

    func refresh() {
        refreshAgentAccessPauseState()
        guard !isLocked else { return }
        renewSession()
        reloadCredentials()
    }

    func timedAllowanceDeadline(for credentialID: String) -> Date? {
        credentialMutations.timedAllowanceDeadline(credentialID)
    }

    @discardableResult
    func revokeTimedAllowance(for credentialID: String) -> Bool {
        credentialMutations.revokeTimedAllowance(credentialID)
    }

}
