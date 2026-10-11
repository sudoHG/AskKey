import AppKit
import SwiftUI
import AskKeyBroker

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
    var windowEventMonitor: Any?
    var managementWindow: NSWindow?
    var windowConfigurationObservers: [NSObjectProtocol] = []
    var managementWindowLifecycleObservers: [NSObjectProtocol] = []
    var statusItemMenuMonitor: Any?
    var approvalPresentationObserver: NSObjectProtocol?
    var screenUnlockObserver: NSObjectProtocol?
    var approvalWakeObserver: NSObjectProtocol?
    var recycleBinCleanupTimer: Timer?
    var lockedApprovalReminderPosted = false
    var lockedApprovalReminderAttempt: UUID?
    lazy var managementSessionLifecycle = ManagementSessionLifecycle { [weak self] in
        self?.vault.lock()
    }
    var brokerServer: BrokerSocketServer?
    var fileWriteCoordinator: BrokerFileWriteCoordinator?
    @Published internal(set) var pendingApprovalCount = 0
    lazy var approvalPresentation = makeApprovalPresentationCoordinator()
    var launchSource = AppLaunchSource.active
    var managementDockPolicy = ManagementDockPolicy()
    var dockPolicyApplicationScheduled = false
    var managementDockStateRefreshScheduled = false
    var isApplyingDockPolicy = false
}
