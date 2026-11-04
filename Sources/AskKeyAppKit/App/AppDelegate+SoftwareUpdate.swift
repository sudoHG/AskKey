import AppKit
import AskKeyBroker
import AskKeyVault

extension AppDelegate {
    /// Creates the updater only for the official Release install (ADR 0011).
    /// Every other build keeps `vault.softwareUpdates` nil, so no Sparkle
    /// object exists and no update control is shown.
    func setupSoftwareUpdates() {
        guard vault.softwareUpdates == nil,
              let makeUpdater = AppRuntimeState.configuration.makeSoftwareUpdater else { return }
        let topology = OfficialInstallTopology.decide(
            bundleURL: Bundle.main.bundleURL,
            isDevelopmentBuild: VaultConfiguration.isDevelopmentBuild
        )
        guard SoftwareUpdateAvailability.isEnabled(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            topology: topology
        ) else { return }
        let gate = SoftwareUpdateRelaunchGate { [weak self] in
            self?.softwareUpdateActivity() ?? .idle
        }
        vault.softwareUpdates = SoftwareUpdateControls(updater: makeUpdater(gate))
    }

    /// Called whenever the pending count changes, so an approval that is
    /// approved but not yet used still postpones a relaunch.
    @discardableResult
    func refreshApprovalActivity() -> (pending: Int, approved: Int) {
        let approvals = Vault.shared.approvalRequests
        return agentActivity.refreshApprovals(pending: approvals.pendingRequests()) { requestID, capability in
            try? approvals.status(requestID: requestID, capability: capability)
        }
    }

    func softwareUpdateActivity() -> SoftwareUpdateActivity {
        let inProgress = refreshApprovalActivity()
        return SoftwareUpdateActivity(
            pendingApprovals: inProgress.pending,
            unusedApprovals: inProgress.approved,
            runningAgentCalls: agentActivity.runningCallCount,
            openWriteSessions: agentActivity.openUploadCount,
            managementAuthenticationActive: ManagementAuthenticationRunner.isPromptShowing
        )
    }

    func checkForUpdatesMenuItem() -> NSMenuItem? {
        guard let updates = vault.softwareUpdates else { return nil }
        let item = NSMenuItem(
            title: appLocalized("Check for Updates…"),
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = updates.canCheckForUpdates
        return item
    }

    @objc func checkForUpdates(_ sender: Any?) {
        vault.softwareUpdates?.checkForUpdates()
    }
}
