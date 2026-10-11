import AppKit
import AskKeyVault

extension AppDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        OnboardingTerminationGate.shouldTerminate(
            hasInFlightWrite: vault.onboarding.hasInFlightWrite,
            arm: { vault.onboarding.writeSettledHandler = $0 }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !ManagementAuthenticationSubprocess.isActive else { return }
        AppRuntimeState.configuration.willStop?()
        brokerServer?.stop()
        recycleBinCleanupTimer?.invalidate()
        if let screenUnlockObserver {
            DistributedNotificationCenter.default.removeObserver(screenUnlockObserver)
        }
        if let approvalWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(approvalWakeObserver)
        }
        Vault.shared.cleanupRuntimeFileDeliveries()
    }
}
