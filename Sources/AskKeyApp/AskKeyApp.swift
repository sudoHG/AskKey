import AppKit
import CoreGraphics
import CoreServices
import SwiftUI
@preconcurrency import UserNotifications
import AskKeyBroker
import AskKeyCore

@MainActor
enum AppRuntimeState {
    private(set) static var normalRuntimeInitialized = false

    static var visualProofEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["ASKKEY_VISUAL_PROOF"] == "1"
            || ProcessInfo.processInfo.environment["ASKKEY_ONBOARDING_PROOF"] == "1"
            || ProcessInfo.processInfo.environment["ASKKEY_ONBOARDING_RESTART_PROOF"] == "1"
#else
        false
#endif
    }

    static func makeVaultViewModel() -> VaultViewModel {
#if DEBUG && ASKKEY_E2E_TESTING
        E2EAppRuntime.prepareIsolation()
#endif
#if DEBUG
        if Bundle.main.object(forInfoDictionaryKey: "AskKeyRequiresDebugRunDirectory") as? Bool == true,
           VaultConfiguration.debugRunDirectory == nil {
            let alert = NSAlert()
            alert.messageText = "请使用隔离启动脚本"
            alert.informativeText = "此测试版本需要显式指定隔离数据目录。请通过交付包中的启动脚本打开。"
            alert.runModal()
            exit(78)
        }
#endif
        normalRuntimeInitialized = true
#if DEBUG && ASKKEY_E2E_TESTING
        return E2EAppRuntime.makeViewModel()
#endif
#if DEBUG
        if visualProofEnabled { return makeVisualProofViewModel() }
#endif
        return VaultViewModel()
    }

#if DEBUG
    private static func makeVisualProofViewModel() -> VaultViewModel {
        guard let defaults = UserDefaults(suiteName: "AskKeyVisualProof") else {
            // The fixed internal suite name is valid; proof must stop instead of polluting app defaults.
            preconditionFailure("AskKey visual proof defaults suite is unavailable")
        }
        let proofLanguage = ProcessInfo.processInfo.environment["ASKKEY_VISUAL_PROOF_LANGUAGE"] ?? "zh-Hans"
        defaults.set(proofLanguage, forKey: "languageMode")
        defaults.set("light", forKey: "appearanceMode")
        defaults.set(true, forKey: "hasCompletedOnboarding")
        let proofRoute = ProcessInfo.processInfo.environment["ASKKEY_VISUAL_PROOF_ROUTE"]
        let proofAuth = ProcessInfo.processInfo.environment["ASKKEY_VISUAL_PROOF_AUTH"] ?? "allow"
        final class VisualProofAuthBox: @unchecked Sendable {
            var onFail: (@MainActor () -> Void)?
        }
        let authBox = VisualProofAuthBox()
        let events = [CredentialAccessEvent(
            timestamp: Date(),
            credentialID: "prod",
            operation: .runtimeRead,
            result: .allowed,
            callerHint: "Codex",
            declaredPurpose: "发布新版本"
        )]
        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: CredentialAccessRecordMutations(list: { events }, clear: { _ in }),
            eraseLocalLibrary: { _, _, _ in },
            unlockVault: {},
            beginManagementSession: { _ in },
            authenticateDeviceOwner: { _ in
                switch proofAuth {
                case "cancel":
                    return nil
                case "fail":
                    authBox.onFail?()
                    return nil
                default:
                    return .allow
                }
            },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(
                isEnabled: { proofRoute != "settings-login-off" },
                setEnabled: { _ in }
            ),
            credentialMutations: .readOnly { ([], [], [], false) }
        )
        model.isVisualProof = true
        authBox.onFail = { [weak model] in
            model?.errorMessage = appLocalized("System authentication failed.")
        }
        model.hasCompletedOnboarding = true
        model.isLocked = true
        model.hasManagementSession = false
        model.iCloudBackupEnabled = true
        model.credentials = [
            .visualProof(
                id: "prod",
                name: "生产环境 API",
                componentNames: ["API_KEY", "API_ENDPOINT"],
                groupName: "发布"
            ),
            .visualProof(
                id: "ssh",
                name: "部署服务器",
                componentNames: ["SSH_HOST"]
            ),
        ]
        model.recycledCredentials = [
            .visualProof(
                id: "old",
                name: "旧数据库账号",
                componentNames: ["DB_HOST", "DB_PASSWORD"],
                deletedAt: Date().addingTimeInterval(-5 * 24 * 60 * 60)
            )
        ]
        model.storedCredentialGroups = ["发布", "空分组"]
        model.credentialAccessRecords = events
        model.pendingApprovalCount = 2
        model.visualProofPendingRequests = [
            .init(
                operationID: "preview-read",
                credentialID: "prod",
                targetID: "prod",
                operation: .read,
                payloadDigest: "redacted",
                credentialName: "生产环境 API",
                callerName: "Codex",
                callerPurpose: "发布新版本"
            ),
            .init(
                operationID: "preview-modify",
                credentialID: "ssh",
                targetID: "ssh",
                operation: .modify,
                payloadDigest: "redacted",
                credentialName: "部署服务器",
                callerName: "Cursor",
                callerPurpose: "更新服务器地址"
            ),
        ]
        model.timedAllowanceEnabled = proofRoute != "approval-timed-disabled"
        if proofRoute == "empty" || proofRoute == "welcome" || proofRoute == "welcome-login-off" {
            model.credentials = []
            model.recycledCredentials = []
            model.storedCredentialGroups = []
        }
        if proofRoute == "recycle-empty" {
            model.recycledCredentials = []
        }
        if proofRoute == "welcome" || proofRoute == "welcome-login-off" {
            model.pendingApprovalCount = 0
            model.visualProofPendingRequests = []
            model.hasCompletedOnboarding = false
        } else if proofRoute == "locked" {
            model.isLocked = true
            model.hasManagementSession = false
        }
        return model
    }
#endif
}

enum AppLaunchSource: Equatable {
    case active
    case loginItem

    init(event: NSAppleEventDescriptor?) {
        guard event?.eventID == AEEventID(kAEOpenApplication),
              event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil else {
            self = .active
            return
        }
        self = .loginItem
    }
}

struct AppLaunchPresentation: Equatable {
    let activationPolicy: NSApplication.ActivationPolicy
    let activatesApplication: Bool
    let hidesMainWindow: Bool

    static func plan(for source: AppLaunchSource) -> Self {
        switch source {
        case .active:
            return .init(
                activationPolicy: .regular,
                activatesApplication: true,
                hidesMainWindow: false
            )
        case .loginItem:
            return .init(
                activationPolicy: .accessory,
                activatesApplication: false,
                hidesMainWindow: true
            )
        }
    }

    func apply(
        setActivationPolicy: (NSApplication.ActivationPolicy) -> Void,
        activateApplication: () -> Void,
        hideMainWindow: () -> Void
    ) {
        setActivationPolicy(activationPolicy)
        if activatesApplication {
            activateApplication()
        } else if hidesMainWindow {
            hideMainWindow()
        }
    }
}

@MainActor
struct ManagementSessionLifecycle {
    enum Event: Equatable {
        case popoverDisappeared
        case applicationDeactivated
        case windowClosed(identifier: String?)
    }

    private let endManagementSession: () -> Void

    init(endManagementSession: @escaping () -> Void) {
        self.endManagementSession = endManagementSession
    }

    func handle(_ event: Event) {
        guard event == .windowClosed(identifier: "settings") else { return }
        endManagementSession()
    }
}

enum AgentApprovalPresentationPlan: Equatable {
    case lockedReminder(title: String, body: String)
    case detailedConfirmation
}

enum AgentApprovalScreenState: Equatable {
    case locked
    case unlocked
    case unknown
}

enum AgentApprovalGatedRequest<Request> {
    case lockedReminder(title: String, body: String)
    case detailed(Request?)
}

enum AgentApprovalPrivacyPolicy {
    static func plan(
        screenState: AgentApprovalScreenState,
        language: String = AppLanguage.current
    ) -> AgentApprovalPresentationPlan {
        switch screenState {
        case .locked, .unknown:
            return .lockedReminder(
                title: AppLanguage.localized("Ask Key has pending requests", language: language),
                body: AppLanguage.localized(
                    "Unlock your Mac to review a pending request.",
                    language: language
                )
            )
        case .unlocked:
            return .detailedConfirmation
        }
    }

    static func gatedRequest<Request>(
        screenState: AgentApprovalScreenState,
        load: () -> Request?
    ) -> AgentApprovalGatedRequest<Request> {
        switch plan(screenState: screenState) {
        case .lockedReminder(let title, let body):
            return .lockedReminder(title: title, body: body)
        case .detailedConfirmation:
            return .detailed(load())
        }
    }
}

enum AgentApprovalRequestSelection {
    static func select(
        _ pending: [BrokerPendingApproval],
        operationID: String?
    ) -> BrokerPendingApproval? {
        guard let operationID else { return pending.first }
        return pending.first { $0.request.operationID == operationID }
    }
}

enum LockedApprovalReminderDeliveryResult: Equatable {
    case authorizationUnavailable
    case delivered
    case deliveryFailed
}

enum LockedApprovalReminderDeliveryPolicy {
    static func marksNotificationPosted(
        for result: LockedApprovalReminderDeliveryResult
    ) -> Bool {
        result == .delivered
    }
}

protocol HostingWindowSizing: AnyObject {
    func stopResizingWindowFromContent()
}

extension NSHostingView: HostingWindowSizing {
    func stopResizingWindowFromContent() {
        sizingOptions = []
    }
}

final class ManagementWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
enum ManagementWindowConfiguration {
    static let frameSize = NSSize(
        width: WorkspaceVisualContract.windowWidth,
        height: WorkspaceVisualContract.windowHeight
    )
    private static var isApplying = false

    static func makeWindow<Content: View>(rootView: Content) -> NSWindow {
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        let window = ManagementWindow(
            contentRect: NSRect(origin: .zero, size: frameSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.contentView = hosting
        apply(to: window)
        window.center()
        return window
    }

    static func apply(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.remove(.resizable)
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        if let sizer = window.contentView as? HostingWindowSizing {
            sizer.stopResizingWindowFromContent()
        }
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        if abs(window.frame.width - frameSize.width) > 2
            || abs(window.frame.height - frameSize.height) > 2 {
            var frame = window.frame
            frame.size = frameSize
            window.setFrame(frame, display: true)
        }
        window.contentMinSize = frameSize
        window.contentMaxSize = frameSize
    }

    static func applyIfSettingsWindow(from note: Notification) {
        guard let window = note.object as? NSWindow,
              window.identifier?.rawValue == "settings" else { return }
        apply(to: window)
    }

    static func installObservers(
        center: NotificationCenter = .default
    ) -> [NSObjectProtocol] {
        [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { note in
                MainActor.assumeIsolated {
                    applyIfSettingsWindow(from: note)
                }
            }
        ]
    }
}

@main
struct AskKeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!ManagementAuthenticationSubprocess.isActive)) {
            VaultPopover(onOpenManagement: appDelegate.openManagementWindow)
                .environment(appDelegate.vault)
                .environment(\.locale, appDelegate.vault.appLocale)
        } label: {
            MenuBarIcon()
            if appDelegate.pendingApprovalCount > 0 {
                Text("\(appDelegate.pendingApprovalCount)")
            }
            if VaultConfiguration.isDevelopmentBuild {
                Text("DEV")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private lazy var normalVault = AppRuntimeState.makeVaultViewModel()
    private lazy var authenticationSubprocessVault = VaultViewModel(
        runtimeFileCleanupFailures: { false }
    )
    var vault: VaultViewModel {
        ManagementAuthenticationSubprocess.isActive
            ? authenticationSubprocessVault
            : normalVault
    }
    lazy var hotkeyManager = GlobalHotkeyManager()
    private var windowEventMonitor: Any?
    private var managementWindow: NSWindow?
    private var windowConfigurationObservers: [NSObjectProtocol] = []
    private var managementWindowLifecycleObservers: [NSObjectProtocol] = []
    private var statusItemMenuMonitor: Any?
    private var approvalPresentationObserver: NSObjectProtocol?
    private var screenUnlockObserver: NSObjectProtocol?
    private var recycleBinCleanupTimer: Timer?
    private var lockedApprovalReminderPosted = false
    private var lockedApprovalReminderAttempt: UUID?
    private lazy var managementSessionLifecycle = ManagementSessionLifecycle { [weak self] in
        self?.vault.lock()
    }
    private var brokerServer: BrokerSocketServer?
    private var fileWriteCoordinator: BrokerFileWriteCoordinator?
    @Published private(set) var pendingApprovalCount = 0
    private var presentingApproval = false
    private var launchSource = AppLaunchSource.active
    private var managementDockPolicy = ManagementDockPolicy()
    private var dockPolicyApplicationScheduled = false
    private var managementDockStateRefreshScheduled = false
    private var isApplyingDockPolicy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ManagementAuthenticationSubprocess.startIfRequested() { return }
        launchSource = AppLaunchSource(event: NSAppleEventManager.shared().currentAppleEvent)
        ensureManagementWindow()
        _ = managementDockPolicy.handle(
            .launch(isActive: launchSource == .active)
        )
        let presentation = AppLaunchPresentation.plan(for: launchSource)
        presentation.apply(
            setActivationPolicy: { [weak self] _ in
                self?.scheduleManagementDockPolicyApplication()
            },
            activateApplication: { NSApp.activate(ignoringOtherApps: true) },
            hideMainWindow: {
                self.hideManagementWindow()
                DispatchQueue.main.async { [weak self] in self?.hideManagementWindow() }
            }
        )
        if launchSource == .active {
            managementWindow?.makeKeyAndOrderFront(nil)
        }
#if DEBUG && ASKKEY_E2E_TESTING
        setupWindowBehavior()
        setupStatusItemMenu()
        setupApprovalQueue()
        Vault.shared.approvalRequests.configureAuthentication { _ in true }
        startBroker()
        E2EAppRuntime.startScenario()
        return
#endif
        if AppRuntimeState.visualProofEnabled {
            setupWindowBehavior()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
#if DEBUG
                if AgentOnboardingDebugSupport.isRequested {
                    guard let self else { return }
                    let window = self.managementWindow ?? NSApp.windows.first {
                        $0.identifier?.rawValue == "settings"
                    }
                    guard let window else {
                        NSLog("AskKey onboarding proof failed: management window is unavailable")
                        NSApp.terminate(nil)
                        return
                    }
                    Task { await AgentOnboardingDebugDriver.run(window: window, vault: self.vault) }
                    return
                }
#endif
                self?.performVisualProofClicks()
            }
            return
        }
        recycleBinCleanupTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            guard !Vault.shared.isLocked else { return }
            do {
                try Vault.shared.purgeExpiredRecycledCredentials()
            } catch {
                NSLog("AskKey: scheduled recycle-bin cleanup failed: \(error.localizedDescription)")
            }
        }
        setupApprovalQueue()
        Vault.shared.updateDefaultTimedAllowanceMinutes(vault.defaultTimedAllowanceMinutes)
        vault.retryBrokerStart = { [weak self] in self?.retryBrokerStart() }
        startBroker()
        if brokerServer != nil {
            do { try Vault.shared.purgeExpiredRecycledCredentials() }
            catch { vault.errorMessage = "Ask Key could not clean up expired recycled credentials." }
        }
#if DEBUG
        if DebugClientE2ERunner.startIfRequested() { return }
#endif
        setupHotkey()
        setupWindowBehavior()
        setupStatusItemMenu()
        NotificationCenter.default.addObserver(
            forName: .askKeyVaultBootstrapDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.brokerServer == nil else { return }
                self.startBroker()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .hotkeyShortcutChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.hotkeyManager.register(GlobalHotkeyManager.Shortcut.fromID(id))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        OnboardingTerminationGate.shouldTerminate(hasInFlightWrite: vault.onboarding.hasInFlightWrite) {
            vault.onboarding.writeSettledHandler = $0
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !ManagementAuthenticationSubprocess.isActive else { return }
        #if DEBUG && ASKKEY_E2E_TESTING
        E2EAppRuntime.stop()
        #endif
        brokerServer?.stop()
        recycleBinCleanupTimer?.invalidate()
        if let screenUnlockObserver {
            DistributedNotificationCenter.default.removeObserver(screenUnlockObserver)
        }
        Vault.shared.cleanupRuntimeFileDeliveries()
    }

    // The public socket is the versioned, allow-listed Broker. Its providers expose
    // only Agent-safe projections; App-only Vault operations never enter the wire
    // protocol.
    private func startBroker() {
        guard brokerServer == nil else { return }
        let topology = OfficialInstallTopology.decide(
            bundleURL: Bundle.main.bundleURL,
            isDevelopmentBuild: VaultConfiguration.isDevelopmentBuild
        )
        guard OfficialInstallTopology.allowsOfficialRuntime(topology) else {
            vault.errorMessage = OfficialInstallCopy.message(for: topology)
            NSLog("AskKey: official runtime disabled because the installation topology is invalid")
            brokerServer?.stop()
            brokerServer = nil
            return
        }
        do {
            try ICloudAppLifecycleController.shared.prepareAgentRuntime()
        } catch {
            if case ICloudAppLifecycleError.restoreSettingsRecoveryFailed = error {
                vault.adoptRestoredPreferences()
                vault.refreshAgentAccessPauseState()
                presentBrokerRuntimeFailure(error)
            } else if case VaultBootstrapError.migrationRequired = error {
                vault.migrationRequired = true
            } else {
                vault.errorMessage = "Ask Key could not prepare Agent access. Open the app to review the vault state."
            }
            NSLog("AskKey: broker disabled because the vault store is unavailable: \(error.localizedDescription)")
            brokerServer?.stop()
            brokerServer = nil
            return
        }
        vault.adoptRestoredPreferences()
        vault.refreshAgentAccessPauseState()
#if !(DEBUG && ASKKEY_E2E_TESTING)
        ICloudAppLifecycleController.shared.startAutomaticScheduling()
        CredentialExpiryReminderController.shared.onAuthorizationFailure = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.vault.errorMessage = message
            }
        }
        CredentialExpiryReminderController.shared.start()
#endif
        let fileWrites: BrokerFileWriteCoordinator
        let socketURL: URL
        do {
            socketURL = try BrokerConfiguration.resolvedSocketURL()
            fileWrites = try BrokerFileWriteCoordinator(
                stagingDirectory: socketURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("file-write-staging", isDirectory: true),
                approvals: Vault.shared.approvalRequests,
                authenticateReveal: { Self.authenticateFileReveal() },
                commitFrozenFile: { [weak self] file in
                    try Vault.shared.commitAgentFileWrite(file)
                    Task { @MainActor [weak self] in self?.vault.refreshCredentialSummary() }
                },
                submitFrozenApproval: { credentialID, expectedDigest, request in
                    do {
                        return try Vault.shared.submitFileWriteApprovalIfCurrent(
                            credentialID: credentialID,
                            expectedPreviousDigest: expectedDigest,
                            request: request
                        )
                    } catch VaultError.agentAccessPaused {
                        throw BrokerProviderError.agentAccessPaused
                    } catch VaultError.credentialUnavailable {
                        throw BrokerProviderError.requestRejected
                    }
                },
                normalizeCreateTarget: {
                    try Vault.shared.normalizeAgentCreateCredentialName($0)
                },
                resolvePreviousDigest: { credentialID in
                    do {
                        return try Vault.shared.brokerFileContentDigest(
                            credentialID: credentialID
                        )
                    } catch VaultError.agentAccessPaused {
                        throw BrokerProviderError.agentAccessPaused
                    } catch VaultError.credentialUnavailable {
                        throw BrokerProviderError.requestRejected
                    }
                },
                completedFileCommit: { requestID, capability, expectedDigest in
                    try Vault.shared.completedAgentFileWrite(requestID: requestID,
                        capability: capability, expectedDigest: expectedDigest)
                }
            )
            fileWriteCoordinator = fileWrites
        } catch {
            presentBrokerRuntimeFailure(error)
            return
        }
        let textRuntime = BrokerTextRuntime(resolveCredentials: { request, cancellation in
            do {
                return try Vault.shared.brokerTextCredentials(for: request, cancellation: cancellation)
            } catch VaultError.agentAccessPaused {
                throw BrokerProviderError.agentAccessPaused
            } catch VaultError.credentialUnavailable {
                throw BrokerProviderError.requestRejected
            }
        })
        let handler = BrokerRequestHandler(
            catalog: {
                do {
                    let catalog = try Vault.shared.brokerCredentialCatalog(cancellation: $0)
                    Vault.shared.recordCredentialAccess(.init(
                        timestamp: Date(), credentialID: nil, operation: .catalog,
                        result: .allowed, callerHint: nil, declaredPurpose: nil
                    ))
                    return catalog
                } catch VaultError.agentAccessPaused {
                    Vault.shared.recordCredentialAccess(.init(
                        timestamp: Date(), credentialID: nil, operation: .catalog,
                        result: .denied, callerHint: nil, declaredPurpose: nil
                    ))
                    throw BrokerProviderError.agentAccessPaused
                }
            },
            requestStatus: { requestID, capability in
                if let completed = try Vault.shared.committedAgentFileWriteStatus(
                    requestID: requestID, capability: capability) {
                    return completed
                }
                do {
                    return try Vault.shared.approvalRequests.status(
                        requestID: requestID,
                        capability: capability
                    )
                } catch BrokerApprovalError.requestNotFound {
                    return Vault.shared.brokerRequests.status(
                        requestID: requestID,
                        capability: capability
                    )
                }
            },
            cancelRequest: { requestID, capability in
                do {
                    return try Vault.shared.approvalRequests.cancel(
                        requestID: requestID,
                        capability: capability
                    )
                } catch BrokerApprovalError.requestNotFound {
                    return Vault.shared.brokerRequests.cancel(
                        requestID: requestID,
                        capability: capability
                    )
                }
            },
            textRun: { request, descriptors, cancellation in
                try textRuntime.run(
                    request,
                    standardInputFD: descriptors.standardInput,
                    standardOutputFD: descriptors.standardOutput,
                    standardErrorFD: descriptors.standardError,
                    controlFD: descriptors.control,
                    cancellation: cancellation
                )
            },
            fileWrite: { try fileWrites.handle($0) },
            submitTextWrite: { request, cancellation in
                try cancellation.check()
                return try mapAgentTextWriteProviderError {
                    try Vault.shared.requestAgentTextWrite(request, fileResolver: { reference in
                        try fileWrites.resolveComponent(reference, operationID: request.operationID)
                    })
                }
            },
            commitTextWrite: { [weak self] request, requestID, capability in
                let result = try mapAgentTextWriteProviderError {
                    try Vault.shared.commitAgentTextWrite(
                        request,
                        requestID: requestID,
                        capability: capability
                    )
                }
                Task { @MainActor [weak self] in self?.vault.refreshCredentialSummary() }
                return result
            },
            cancelTextWrite: { operationID, requestID, capability in
                try mapAgentTextWriteProviderError {
                    try Vault.shared.cancelAgentTextWrite(
                        operationID: operationID,
                        requestID: requestID,
                        capability: capability
                    )
                }
            }
        )
        let server = BrokerSocketServer(
            socketPath: BrokerConfiguration.socketURL.path,
            handler: handler
        )
        do {
            try server.start()
            brokerServer = server
            vault.clearBrokerRuntimeFailure()
            vault.refreshAgentAccessPauseState()
        } catch {
            presentBrokerRuntimeFailure(error)
        }
    }

    private func presentBrokerRuntimeFailure(_ error: Error) {
        vault.presentBrokerRuntimeFailure(error)
        vault.retryBrokerStart = { [weak self] in
            self?.retryBrokerStart()
        }
        NSLog("AskKey: broker runtime is unavailable")
    }

    private func retryBrokerStart() {
        var recovery = BrokerRuntimeRecovery(
            isRunning: { [weak self] in self?.brokerServer != nil },
            start: { [weak self] in
                guard let self else { return }
                self.startBroker()
                if self.brokerServer == nil, self.vault.brokerRecoveryAvailable {
                    throw BrokerFileWriteError.stagingFailed
                }
            }
        )
        _ = recovery.retry()
    }

    nonisolated private static func authenticateFileReveal() -> Bool {
        return ManagementAuthenticationRunner.shared.authenticateBlocking(
            presentation: ManagementAuthenticationPresentation.current(
                reason: "View the frozen file submitted for approval"
            )
        )
    }

    private func setupApprovalQueue() {
        Vault.shared.approvalRequests.configureAuthentication { purpose in
            let reason = purpose == .readApproval
                ? ManagementAuthenticationAction.approveRead.reasonKey
                : ManagementAuthenticationAction.approveWrite.reasonKey
            return ManagementAuthenticationRunner.shared.authenticateBlocking(
                presentation: ManagementAuthenticationPresentation.current(reason: reason)
            )
        }
        Vault.shared.approvalRequests.configureObservers(
            notify: { _ in },
            pendingCountChanged: { [weak self] count in
                Task { @MainActor [weak self] in
                    self?.pendingApprovalCount = count
                    self?.vault.pendingApprovalCount = count
                    if count == 0 { self?.resetLockedApprovalReminder() }
                    if count > 0 { self?.presentPendingApproval() }
                }
            }
        )
        approvalPresentationObserver = NotificationCenter.default.addObserver(
            forName: .presentNextAgentApproval, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.presentPendingApproval(operationID: note.object as? String)
            }
        }
        screenUnlockObserver = DistributedNotificationCenter.default.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetLockedApprovalReminder()
                self?.presentPendingApproval()
            }
        }
    }

    private func presentPendingApproval(operationID: String? = nil) {
        guard !presentingApproval else { return }
        let pending: BrokerPendingApproval
        switch AgentApprovalPrivacyPolicy.gatedRequest(
            screenState: Self.screenState(),
            load: {
                AgentApprovalRequestSelection.select(
                    Vault.shared.approvalRequests.pendingRequests(),
                    operationID: operationID
                )
            }
        ) {
        case .lockedReminder(let title, let body):
            postLockedApprovalReminder(title: title, body: body)
            return
        case .detailed(let loaded):
            guard let loaded else { return }
            pending = loaded
            resetLockedApprovalReminder()
        }
        presentingApproval = true
        NSApp.activate(ignoringOtherApps: true)

        let request = pending.request
        runFrozenApprovalPanel(request: request, expiresAt: pending.expiresAt, pending: pending) { [weak self] decision in
        guard let self else { return }
        guard let decision else {
            self.presentingApproval = false
            return
        }
        let fileWrites = self.fileWriteCoordinator
        let applyDecision: @Sendable () -> Void = { [weak self, fileWrites] in
            var didFail = false
            do {
                _ = try Vault.shared.approvalRequests.decide(
                    requestID: pending.requestID,
                    capability: pending.capability,
                    decision: decision
                )
                if decision != .deny,
                   let fileWrites,
                   let summary = try? fileWrites.summary(requestID: pending.requestID) {
                    try fileWrites.commit(
                        requestID: pending.requestID,
                        capability: pending.capability,
                        expectedDigest: summary.digest
                    )
                }
            } catch {
                didFail = true
            }
            let failed = didFail
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.presentingApproval = false
                if failed {
                    self.vault.errorMessage = "Ask Key could not apply this decision. Open Pending requests to retry or reject it."
                } else if !Vault.shared.approvalRequests.pendingRequests().isEmpty {
                    self.presentPendingApproval()
                }
            }
        }
        if decision == .deny {
            applyDecision()
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: applyDecision)
        }
        }
    }

    private func runFrozenApprovalPanel(
        request: BrokerApprovalOperationRequest,
        expiresAt: Date?,
        pending: BrokerPendingApproval? = nil,
        completion: @escaping @MainActor (BrokerApprovalDecision?) -> Void = { _ in }
    ) {
        var finished = false
        var privacyTimer: Timer?
        let contentSize = NSSize(
            width: 360,
            height: request.operation == .read ? 430 : 540
        )
        let panel = AgentApprovalPanelFactory.make(contentSize: contentSize)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let finish: (BrokerApprovalDecision?) -> Void = { value in
            guard !finished else { return }
            finished = true
            privacyTimer?.invalidate()
            privacyTimer = nil
            panel.orderOut(nil)
            panel.contentViewController = nil
            let valid = Self.screenState() == .unlocked && expiresAt.map({ $0 > Date() }) != false
            completion(valid ? value : nil)
        }
        panel.contentViewController = NSHostingController(
            rootView: FrozenAgentApprovalPrompt(
                request: request,
                trustedCredentialName: pending?.trustedCredentialName,
                expiresAt: expiresAt,
                timedAllowanceEnabled: vault.timedAllowanceEnabled,
                timedAllowanceMinutes: vault.defaultTimedAllowanceMinutes,
                writeSummary: pending.flatMap {
                    try? Vault.shared.frozenAgentWriteSummary(
                        operationID: $0.request.operationID,
                        requestID: $0.requestID, capability: $0.capability
                    )
                },
                revealMaterial: pending.map { frozenPending in
                    { [weak self] in
                        guard let self, Self.screenState() == .unlocked else {
                            throw BrokerApprovalError.requestNotFound
                        }
                        let fileWrites = self.fileWriteCoordinator
                        let material = try await Task.detached(priority: .userInitiated) {
                            if let fileWrites, (try? fileWrites.summary(requestID: frozenPending.requestID)) != nil {
                                let file = try fileWrites.reveal(requestID: frozenPending.requestID)
                                return FrozenApprovalMaterial(
                                    title: file.originalFilename + " · " + String(file.byteCount) + " B",
                                    content: String(data: file.bytes, encoding: .utf8) ?? file.bytes.base64EncodedString(),
                                    encoding: String(data: file.bytes, encoding: .utf8) == nil ? "Base64" : "UTF-8"
                                )
                            }
                            guard ManagementAuthenticationRunner.shared.authenticateBlocking(
                                presentation: .current(reason: ManagementAuthenticationAction.revealFrozenFile.reasonKey)
                            ) else { throw BrokerFileWriteError.authenticationFailed }
                            let material = try Vault.shared.revealFrozenCredentialWrite(
                                operationID: frozenPending.request.operationID,
                                requestID: frozenPending.requestID,
                                capability: frozenPending.capability,
                                using: .allow
                            )
                            func describe(_ inputs: [CredentialComponentInput]) -> String {
                                inputs.map { item in
                                    let value: String
                                    switch item.value {
                                    case .text(let text): value = text
                                    case .file(let filename, let bytes):
                                        value = filename + " (" + String(bytes.count) + " B)\n"
                                            + (String(data: bytes, encoding: .utf8) ?? "Base64: " + bytes.base64EncodedString())
                                    }
                                    return item.name + "\n" + value
                                }.joined(separator: "\n\n")
                            }
                            return FrozenApprovalMaterial(
                                title: material.credentialName,
                                content: FrozenWriteRevealCopy.content(
                                    before: describe(material.before),
                                    after: describe(material.after)
                                ),
                                encoding: "UTF-8 / Base64"
                            )
                        }.value
                        guard Self.screenState() == .unlocked else { throw BrokerApprovalError.requestNotFound }
                        return material
                    }
                },
                finish: finish
            )
        )
        panel.setContentSize(contentSize)
        panel.contentViewController?.view.frame = NSRect(origin: .zero, size: contentSize)
        panel.center()
        if AppRuntimeState.visualProofEnabled {
            panel.makeKeyAndOrderFront(nil)
            if let view = panel.contentViewController?.view {
                captureVisualProof(view: view)
            }
        }
        privacyTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let requestEnded = pending.map {
                    (try? Vault.shared.approvalRequests.status(requestID: $0.requestID, capability: $0.capability)) != .pending
                } ?? false
                if Self.screenState() != .unlocked || expiresAt.map({ $0 <= Date() }) == true || requestEnded {
                    finish(nil)
                    if Self.screenState() == .unlocked { self.presentPendingApproval() }
                }
            }
        }
        panel.level = .modalPanel
        panel.makeKeyAndOrderFront(nil)
    }

    private func performVisualProofClicks() {
#if DEBUG
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "settings"
        }), let view = window.contentView else {
            NSLog("AskKey visual proof failed: management window is unavailable")
            return
        }
        let route = ProcessInfo.processInfo.environment["ASKKEY_VISUAL_PROOF_ROUTE"] ?? "locked"
        if route != "locked", !route.hasPrefix("welcome"), !vault.hasManagementSession {
            Task { [weak self] in
                await self?.vault.unlockForManagement()
                if self?.vault.hasManagementSession == true {
                    self?.performVisualProofClicks()
                    return
                }
                let auth = ProcessInfo.processInfo.environment["ASKKEY_VISUAL_PROOF_AUTH"]
                if auth == "cancel" || auth == "fail" {
                    self?.captureVisualProof(view: view)
                }
            }
            return
        }
#if DEBUG
        if (route == "approval" || route == "approval-timed-disabled"),
           let request = vault.visualProofPendingRequests.first {
            _ = runFrozenApprovalPanel(
                request: request,
                expiresAt: Date().addingTimeInterval(300)
            )
            return
        }
#endif
        let fallbackPoints: [String: NSPoint] = [
            "group": .init(x: 100, y: 490),
            "group-empty": .init(x: 100, y: 450),
            "ungrouped": .init(x: 100, y: 410),
            "recycle": .init(x: 100, y: 370),
            "pending": .init(x: 100, y: 135),
            "approval": .init(x: 100, y: 135),
            "records": .init(x: 100, y: 100),
            "agent": .init(x: 100, y: 75),
            "detail": .init(x: 520, y: 500),
            "chooser": .init(x: 900, y: 550),
            "import": .init(x: 780, y: 550),
        ]
        window.makeKeyAndOrderFront(nil)
        let proofModifiers: NSEvent.ModifierFlags = [.command, .option]
        let sequences: [String: [(String, UInt16, NSEvent.ModifierFlags)]] = [
            "group": [("1", 18, proofModifiers)],
            "group-confirm": [("1", 18, proofModifiers), ("d", 2, proofModifiers)],
            "group-empty": [("2", 19, proofModifiers)],
            "ungrouped": [("3", 20, proofModifiers)],
            "recycle": [("4", 21, proofModifiers)],
            "chooser": [("n", 45, proofModifiers)],
            "import": [("i", 34, proofModifiers)],
            "editor": [("n", 45, proofModifiers), ("6", 22, proofModifiers)],
            "editor-expanded": [("n", 45, proofModifiers), ("6", 22, proofModifiers), ("e", 14, proofModifiers)],
            "editor-custom-visible": [("n", 45, proofModifiers), ("6", 22, proofModifiers), ("f", 3, proofModifiers)],
            "editor-protected": [("n", 45, proofModifiers), ("0", 29, proofModifiers), ("f", 3, proofModifiers)],
            "editor-protected-revealed": [("n", 45, proofModifiers), ("0", 29, proofModifiers), ("f", 3, proofModifiers), ("r", 15, proofModifiers)],
            "editor-more-open": [("n", 45, proofModifiers), ("6", 22, proofModifiers), ("f", 3, proofModifiers)],
            "editor-more-closed": [("n", 45, proofModifiers), ("6", 22, proofModifiers), ("f", 3, proofModifiers)],
            "editor-save": [("n", 45, proofModifiers), ("6", 22, proofModifiers), ("s", 1, proofModifiers)],
            "import-preview": [("i", 34, proofModifiers), ("p", 35, proofModifiers)],
            "import-conflict": [("i", 34, proofModifiers), ("c", 8, proofModifiers)],
            "import-save": [("i", 34, proofModifiers), ("s", 1, proofModifiers)],
            "detail-delete": [("v", 9, proofModifiers), ("x", 7, proofModifiers)],
            "detail-delete-confirm": [("v", 9, proofModifiers), ("d", 2, proofModifiers)],
            "detail-edit": [("v", 9, proofModifiers), ("j", 38, proofModifiers)],
            "recycle-empty": [("4", 21, proofModifiers)],
            "settings-restore": [(",", 43, .command), ("r", 15, proofModifiers)],
            "settings-erase": [(",", 43, .command), ("x", 7, proofModifiers)],
            "settings-record-clear": [(",", 43, .command), ("c", 8, proofModifiers)],
        ]
        if let sequence = sequences[route] {
            runVisualProofSequence(sequence, index: 0, route: route, window: window)
            return
        }
        if route == "settings" || route == "settings-warning" || route == "settings-login-off" {
            guard sendVisualProofKey(",", keyCode: 43, modifiers: .command, to: window) else {
                return
            }
            scheduleVisualProofAfterFirstAction(route: route, window: window)
            return
        }
        guard let fallbackPoint = fallbackPoints[route],
              view.bounds.contains(fallbackPoint) else {
            captureVisualProof(view: view)
            return
        }
        guard sendVisualProofClick(at: fallbackPoint, to: window) else {
            NSLog("AskKey visual proof failed: click event could not be delivered for \(route)")
            return
        }
        scheduleVisualProofAfterFirstAction(route: route, window: window)
#endif
    }

    private func runVisualProofSequence(
        _ sequence: [(String, UInt16, NSEvent.ModifierFlags)],
        index: Int,
        route: String,
        window: NSWindow
    ) {
#if DEBUG
        guard index < sequence.count else {
            guard route != "approval", let view = window.contentView else { return }
            if route == "editor-more-open" || route == "editor-more-closed" {
                let rowTrailingPoint = NSPoint(x: 850, y: 210)
                guard sendVisualProofClick(at: rowTrailingPoint, to: window) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self else { return }
                    if route == "editor-more-closed" {
                        guard self.sendVisualProofClick(at: rowTrailingPoint, to: window) else {
                            return
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        self.captureVisualProof(view: view)
                    }
                }
                return
            }
            captureVisualProof(view: view)
            return
        }
        let key = sequence[index]
        guard sendVisualProofKey(key.0, keyCode: key.1, modifiers: key.2, to: window) else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak window] in
            guard let self, let window else { return }
            self.runVisualProofSequence(
                sequence,
                index: index + 1,
                route: route,
                window: window
            )
        }
#endif
    }

    private func scheduleVisualProofAfterFirstAction(route: String, window: NSWindow) {
#if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak window] in
            guard let self, let window, let view = window.contentView else { return }
            if route == "settings-warning" {
                guard self.sendVisualProofKey(
                    "d",
                    keyCode: 2,
                    modifiers: [.command, .option],
                    to: window
                ) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.captureVisualProof(view: view)
                }
                return
            }
            if route == "approval" {
                _ = self.sendVisualProofKey(
                    "\r",
                    keyCode: 36,
                    modifiers: [],
                    to: window
                )
            } else {
                self.captureVisualProof(view: view)
            }
        }
#endif
    }

    @discardableResult
    private func sendVisualProofKey(
        _ characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        to window: NSWindow
    ) -> Bool {
#if DEBUG
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ), let up = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return false }
        if window.performKeyEquivalent(with: down) { return true }
        NSApp.sendEvent(down)
        NSApp.sendEvent(up)
        return true
#else
        return false
#endif
    }

    @discardableResult
    private func sendVisualProofClick(at point: NSPoint, to window: NSWindow) -> Bool {
#if DEBUG
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else { return false }
        window.sendEvent(down)
        window.sendEvent(up)
        return true
#else
        return false
#endif
    }

    private func captureVisualProof(view: NSView) {
#if DEBUG
        guard let path = ProcessInfo.processInfo.environment["ASKKEY_VISUAL_PROOF_OUTPUT"] else {
            NSLog("AskKey visual proof failed: output path is missing")
            return
        }
        guard !view.bounds.isEmpty else {
            NSLog("AskKey visual proof failed: capture view is empty")
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("AskKey visual proof failed: bitmap representation is unavailable")
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            NSLog("AskKey visual proof failed: PNG encoding failed")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            NSLog("AskKey visual proof capture failed: \(error.localizedDescription)")
        }
#endif
    }

    nonisolated private static func screenState() -> AgentApprovalScreenState {
        AgentApprovalScreenSession.current()
    }

    private func postLockedApprovalReminder(title: String, body: String) {
        NSApp.dockTile.badgeLabel = "!"
        guard !lockedApprovalReminderPosted, lockedApprovalReminderAttempt == nil else { return }
        let attempt = UUID()
        lockedApprovalReminderAttempt = attempt
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                Task { @MainActor [weak self] in
                    guard self?.lockedApprovalReminderAttempt == attempt else { return }
                    self?.lockedApprovalReminderAttempt = nil
                    self?.lockedApprovalReminderPosted = LockedApprovalReminderDeliveryPolicy
                        .marksNotificationPosted(for: .authorizationUnavailable)
                    NSLog(
                        "AskKey: locked approval notification unavailable; using Dock badge fallback"
                    )
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: "askkey-locked-approval-reminder",
                content: content,
                trigger: nil
            )
            center.add(request) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard self?.lockedApprovalReminderAttempt == attempt else { return }
                    self?.lockedApprovalReminderAttempt = nil
                    let result: LockedApprovalReminderDeliveryResult = error == nil
                        ? .delivered
                        : .deliveryFailed
                    self?.lockedApprovalReminderPosted = LockedApprovalReminderDeliveryPolicy
                        .marksNotificationPosted(for: result)
                    if let error {
                        NSLog(
                            "AskKey: locked approval reminder failed; using Dock badge fallback: \(error.localizedDescription)"
                        )
                    }
                }
            }
        }
    }

    private func resetLockedApprovalReminder() {
        lockedApprovalReminderAttempt = nil
        lockedApprovalReminderPosted = false
        NSApp.dockTile.badgeLabel = nil
    }

    private func approvalTitle(for request: BrokerApprovalOperationRequest) -> String {
        let caller = request.callerName ?? appLocalized("Local Agent")
        switch request.operation {
        case .read: return "\(caller) requests a credential"
        case .create: return "\(caller) requests to create a credential"
        case .modify: return "\(caller) requests to modify a credential"
        case .delete: return "\(caller) requests to delete a credential"
        }
    }

    private func approvalDetails(for request: BrokerApprovalOperationRequest) -> String {
        var lines = ["Credential: \(request.credentialName ?? request.targetID)"]
        if let purpose = request.callerPurpose, !purpose.isEmpty {
            lines.append("Purpose: \(purpose)")
        }
        lines.append("Caller identity is self-declared and has not been verified.")
        return lines.joined(separator: "\n")
    }

    private func setupWindowBehavior() {
        NSApp.windows
            .filter { $0.identifier?.rawValue == "settings" }
            .forEach(ManagementWindowConfiguration.apply)
        windowEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2,
                  let window = event.window,
                  window.identifier?.rawValue == "settings" else { return event }

            let location = event.locationInWindow
            let windowHeight = window.frame.height
            guard location.y > windowHeight - 54 else { return event }

            if let hit = window.contentView?.hitTest(location), hit is NSControl {
                return event
            }

            return nil
        }
        windowConfigurationObservers = ManagementWindowConfiguration.installObservers()
        setupManagementWindowLifecycle()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        openManagementWindow()
        return true
    }

    func openManagementWindow() {
        launchSource = .active
        _ = managementDockPolicy.handle(.applicationDidBecomeActive)
        NSApp.activate(ignoringOtherApps: true)
        ensureManagementWindow()
        managementWindow?.deminiaturize(nil)
        managementWindow?.makeKeyAndOrderFront(nil)
        handleManagementDockEvent(.managementWindowOpenedByUser)
        syncManagementWindowDockState()
    }

    private func ensureManagementWindow() {
        if let managementWindow {
            ManagementWindowConfiguration.apply(to: managementWindow)
            return
        }
        let window = ManagementWindowConfiguration.makeWindow(
            rootView: SettingsView()
                .environment(vault)
                .environment(\.locale, vault.appLocale)
                .frame(
                    width: WorkspaceVisualContract.windowWidth,
                    height: WorkspaceVisualContract.windowHeight
                )
        )
        window.title = vault.brandName
        managementWindow = window
    }

    private func hideManagementWindow() {
        managementWindow?.orderOut(nil)
        syncManagementWindowDockState()
    }

    private func isManagementWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "settings"
    }

    private func handleManagementDockEvent(_ event: ManagementDockPolicy.Event) {
        guard !ManagementAuthenticationSubprocess.isActive else { return }
        if isApplyingDockPolicy {
            scheduleManagementDockStateRefresh()
            return
        }
        _ = managementDockPolicy.handle(event)
        scheduleManagementDockPolicyApplication()
    }

    private func syncManagementWindowDockState() {
        guard !ManagementAuthenticationSubprocess.isActive else { return }
        guard let window = managementWindow else {
            handleManagementDockEvent(.managementWindowState(
                visible: false,
                miniaturized: false,
                key: false,
                applicationActive: NSApp.isActive
            ))
            return
        }
        handleManagementDockEvent(.managementWindowState(
            visible: window.isVisible,
            miniaturized: window.isMiniaturized,
            key: window.isKeyWindow,
            applicationActive: NSApp.isActive
        ))
    }

    private func scheduleManagementDockPolicyApplication() {
        guard !ManagementAuthenticationSubprocess.isActive,
              !dockPolicyApplicationScheduled else { return }
        dockPolicyApplicationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dockPolicyApplicationScheduled = false
            self.applyManagementDockPolicy()
        }
    }

    private func scheduleManagementDockStateRefresh() {
        guard !managementDockStateRefreshScheduled else { return }
        managementDockStateRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.managementDockStateRefreshScheduled = false
            if NSApp.isActive {
                self.handleManagementDockEvent(.applicationDidBecomeActive)
            } else {
                self.handleManagementDockEvent(.applicationDidResignActive)
            }
            self.syncManagementWindowDockState()
        }
    }

    private func applyManagementDockPolicy() {
        guard !ManagementAuthenticationSubprocess.isActive else { return }
        guard !isApplyingDockPolicy else {
            scheduleManagementDockPolicyApplication()
            return
        }
        let desired = managementDockPolicy.activationPolicy
        guard NSApp.activationPolicy() != desired else { return }
        isApplyingDockPolicy = true
        defer { isApplyingDockPolicy = false }
        _ = NSApp.setActivationPolicy(desired)
    }

    private func setupManagementWindowLifecycle() {
        let center = NotificationCenter.default
        let windowNotifications: [NSNotification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
        ]
        var observers: [NSObjectProtocol] = windowNotifications.map { notification in
            center.addObserver(forName: notification, object: nil, queue: .main) {
                [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard let self, self.isManagementWindow(window) else { return }
                    if notification == NSWindow.willCloseNotification {
                        self.managementSessionLifecycle.handle(
                            .windowClosed(identifier: window.identifier?.rawValue)
                        )
                        self.handleManagementDockEvent(.managementWindowState(
                            visible: false,
                            miniaturized: false,
                            key: false,
                            applicationActive: NSApp.isActive
                        ))
                    } else {
                        self.syncManagementWindowDockState()
                    }
                }
            }
        }
        observers.append(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleManagementDockEvent(.applicationDidBecomeActive)
                    self?.syncManagementWindowDockState()
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleManagementDockEvent(.applicationDidResignActive)
                }
            }
        )
        managementWindowLifecycleObservers = observers
    }

    // MenuBarExtra has no public right-click API, so intercept right-clicks on the
    // status bar item's window and show a Quit menu there.
    private func setupStatusItemMenu() {
        statusItemMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard let window = event.window,
                  NSStringFromClass(type(of: window)).contains("NSStatusBarWindow"),
                  let contentView = window.contentView else { return event }

            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: appLocalized("Quit Ask Key"),
                                    action: #selector(NSApplication.terminate(_:)),
                                    keyEquivalent: "q"))
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
            return nil
        }
    }

    private func setupHotkey() {
        hotkeyManager.onActivate = { [weak self] in
            self?.togglePopover()
        }
        let shortcut = GlobalHotkeyManager.Shortcut.fromID(AppPreferences().hotkeyShortcutID)
        hotkeyManager.register(shortcut)
    }

    // MenuBarExtra exposes no API to open its popover programmatically, so locate
    // the status item's button and synthesize a click — the same toggle a real
    // click performs (opening it, or closing it if already open).
    private func togglePopover() {
        guard let button = statusItemButton() else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        button.performClick(nil)
    }

    private func statusItemButton() -> NSStatusBarButton? {
        for window in NSApp.windows
        where NSStringFromClass(type(of: window)).contains("NSStatusBarWindow") {
            if let button = window.contentView?.firstDescendant(ofType: NSStatusBarButton.self) {
                return button
            }
        }
        return nil
    }
}

struct FrozenApprovalMaterial: Sendable {
    let title: String
    let content: String
    let encoding: String
}

enum FrozenWriteRevealCopy {
    static func content(before: String, after: String) -> String {
        appLocalized("Before") + "\n" + before
            + "\n\n" + appLocalized("After") + "\n" + after
    }
}

struct FrozenAgentApprovalPrompt: View {
    let request: BrokerApprovalOperationRequest
    var trustedCredentialName: String? = nil
    var expiresAt: Date? = nil
    let timedAllowanceEnabled: Bool
    var timedAllowanceMinutes: Int = 30
    var writeSummary: BrokerCredentialWriteSummary? = nil
    var revealMaterial: (@MainActor () async throws -> FrozenApprovalMaterial)? = nil
    let finish: (BrokerApprovalDecision?) -> Void
    @State private var revealedMaterial: FrozenApprovalMaterial?
    @State private var revealing = false
    @State private var revealFailed = false
    @State private var revealTask: Task<Void, Never>?

    private var caller: String { request.callerName ?? appLocalized("Local Agent") }
    private var credential: String { trustedCredentialName ?? request.credentialName ?? request.targetID }
    private var operationTitle: String {
        switch request.operation {
        case .read: return appLocalizedFormat("%@ requests to use a credential", caller)
        case .create: return appLocalizedFormat("%@ requests to create a credential", caller)
        case .modify: return appLocalizedFormat("%@ requests to modify a credential", caller)
        case .delete: return appLocalizedFormat("%@ requests to delete a credential", caller)
        }
    }

    var body: some View {
        let _ = AppLanguage.store.resolved
        VStack(spacing: 10) {
            Text(appLocalized("Brand monogram"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Theme.brand.gradient, in: .rect(cornerRadius: 11))
            Text(appLocalized("ASK KEY · AGENT REQUEST"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            Text(operationTitle)
                .font(.system(size: 14.5, weight: .bold))
            VStack(alignment: .leading, spacing: 7) {
                approvalRow(appLocalized("Caller"), caller, badge: appLocalized("Declared · Unverified"))
                approvalRow(appLocalized("Credential"), credential)
                if let purpose = request.callerPurpose, !purpose.isEmpty {
                    approvalRow(appLocalized("Purpose"), purpose)
                }
                if request.operation == .delete {
                    approvalRow(appLocalized("Destination"), appLocalized("Recycle Bin · Recoverable for 30 days"))
                }
            }
            .padding(11)
            .background(Theme.neutral(0.055), in: .rect(cornerRadius: 10))
            Text(appLocalized("Caller identity is self-declared and unverified. Decide from the credential and purpose."))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let writeSummary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appLocalized("Before"))
                        ForEach(Array(writeSummary.before.enumerated()), id: \.offset) { _, item in
                            Text("\(item.name) · \(item.byteCount) B · \(item.delivery.environmentVariable ?? "App")")
                        }
                        Text(appLocalized("After"))
                        ForEach(Array(writeSummary.after.enumerated()), id: \.offset) { _, item in
                            Text("\(item.name) · \(item.byteCount) B · \(item.delivery.environmentVariable ?? "App")")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 10)).frame(maxHeight: 70)
            }
            if request.operation != .read {
                VStack(alignment: .leading, spacing: 6) {
                    Text(appLocalized("Frozen Content to Write"))
                        .font(.system(size: 11, weight: .semibold))
                    if let revealedMaterial {
                        HStack {
                            Text(revealedMaterial.title).lineLimit(1)
                            Spacer()
                            Text(revealedMaterial.encoding).foregroundStyle(Theme.textMuted)
                            Button(appLocalized("Hide")) { self.revealedMaterial = nil }
                        }.font(.system(size: 10))
                        ScrollView {
                            Text(verbatim: revealedMaterial.content)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 85)
                    } else {
                        HStack {
                            Text("••••••••").foregroundStyle(Theme.textMuted)
                            Spacer()
                            Button(appLocalized("Authenticate and View")) {
                                guard let revealMaterial, !revealing else { return }
                                revealing = true
                                revealFailed = false
                                revealTask = Task {
                                    defer { revealing = false }
                                    do {
                                        let material = try await revealMaterial()
                                        guard !Task.isCancelled else { return }
                                        revealedMaterial = material
                                    } catch {
                                        if !Task.isCancelled { revealFailed = true }
                                    }
                                }
                            }
                            .disabled(revealMaterial == nil || revealing)
                            .accessibilityIdentifier("approval-reveal-frozen-material")
                        }
                        Text(appLocalized("Viewing requires separate authentication and does not approve this request."))
                            .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    }
                    if revealFailed {
                        Text(appLocalized("Unable to view: authentication was not completed or the request is no longer valid."))
                            .font(.system(size: 10)).foregroundStyle(Theme.red)
                    }
                }
                .padding(10)
                .background(Theme.neutral(0.055), in: .rect(cornerRadius: 8))
            }
            VStack(spacing: 7) {
                Button { finish(.once) } label: {
                    Text(primaryTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Theme.brand, in: .rect(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("approval-allow-once")
                if request.operation == .read, timedAllowanceEnabled {
                    Button {
                        finish(.timedAllow(duration: nil))
                    } label: {
                        VStack(spacing: 1) {
                            Text(appLocalizedFormat("Allow for %lld Minutes", timedAllowanceMinutes))
                            Text(appLocalized("Applies to all local callers for this credential · Revocable anytime"))
                                .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.white, in: .rect(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.sep))
                    }
                    .buttonStyle(.plain)
                }
                Button { finish(.deny) } label: {
                    Text(appLocalized("Deny"))
                        .foregroundStyle(Theme.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("approval-deny")
            }
            .frame(maxWidth: .infinity)
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(appLocalized("Remaining ") + FrozenCountdown.format(deadline: expiresAt, now: context.date))
                }
                Spacer()
                Button(appLocalized("Press ESC to Decide Later")) { finish(nil) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textMuted)
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .environment(\.locale, AppLanguage.store.locale)
        .onDisappear { revealTask?.cancel(); revealTask = nil; revealedMaterial = nil }
    }

    private var primaryTitle: String {
        switch request.operation {
        case .read: return appLocalized("Allow Once")
        case .create: return appLocalized("Approve Creation")
        case .modify: return appLocalized("Approve Change")
        case .delete: return appLocalized("Approve Deletion")
        }
    }

    private func approvalRow(_ label: String, _ value: String, badge: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(Theme.textMuted).frame(width: 44, alignment: .leading)
            Text(value).fontWeight(.medium)
            if let badge {
                Text(badge)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.amber.opacity(0.13), in: .rect(cornerRadius: 4))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }
}

enum FrozenApprovalActions {
    static func titles(
        operation: BrokerApprovalOperation,
        timedAllowanceEnabled: Bool
    ) -> [String] {
        switch operation {
        case .read:
            return timedAllowanceEnabled
                ? ["仅本次", "允许 30 分钟", "拒绝"]
                : ["仅本次", "拒绝"]
        case .create: return ["批准创建", "拒绝"]
        case .modify: return ["批准修改", "拒绝"]
        case .delete: return ["批准删除", "拒绝"]
        }
    }
}

extension Notification.Name {
    static let askKeyVaultBootstrapDidChange = Notification.Name("askKeyVaultBootstrapDidChange")
    static let presentNextAgentApproval = Notification.Name("presentNextAgentApproval")
}

private func mapAgentTextWriteProviderError<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch BrokerApprovalError.capacityReached {
        throw BrokerProviderError.resourceExhausted
    } catch BrokerApprovalError.requestNotFound {
        throw BrokerProviderError.requestNotFound
    } catch BrokerApprovalError.invalidRequest,
            BrokerApprovalError.payloadMismatch,
            BrokerApprovalError.invalidDecision,
            BrokerApprovalError.alreadyConsumed {
        throw BrokerProviderError.invalidRequest
    } catch BrokerApprovalError.agentAccessPaused, VaultError.agentAccessPaused {
        throw BrokerProviderError.agentAccessPaused
    } catch VaultError.credentialUnavailable, VaultError.credentialNotFound {
        throw BrokerProviderError.requestNotFound
    } catch {
        throw error
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let found = subview.firstDescendant(ofType: type) { return found }
        }
        return nil
    }
}
