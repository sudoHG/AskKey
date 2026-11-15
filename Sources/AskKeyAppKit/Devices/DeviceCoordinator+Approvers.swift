import AskKeyDevices
import AskKeyVault
import Foundation

/// Which paired iPhones the Broker's active-approver set holds (ADR 0014 →
/// Approvers, #336). Pairing an iPhone writes its approval flag in the same
/// list write that adds it; the coordinator then adds that pairing ID alone
/// to the set, and repairs any flagged entry the set is missing whenever it
/// reads the list. Removing the pairing is the only way approval stops.
extension DeviceCoordinator {
    /// Device services ready with the list's account available.
    var canActivateApprovers: Bool {
        services != nil && availability == .ready && account == .available
    }

    /// Loads the set from the list once the services are ready with the
    /// list's account: every flagged entry gets a new generation, except one
    /// whose removal began, also when its write failed or is still pending.
    func activateApproversIfNeeded() {
        guard canActivateApprovers, !approversLoaded else { return }
        trackPendingRequestsBeforeActivation()
        do {
            try vault.activateStoredApprovers(excluding: revokedApprovers)
            approversLoaded = true
        } catch {
            environment.log(.approverActivationFailed)
        }
    }

    /// A pairing added `pairingID` to the list: it joins the set alone as
    /// soon as the coordinator learns of the add, whether or not the pairing
    /// sheet is still open, so the other approvers keep their generations.
    func pairingAdded(_ pairingID: PairingID) {
        guard canActivateApprovers else { return }
        guard approversLoaded else { return activateApproversIfNeeded() }
        activateMissingApprover(pairingID)
    }

    /// Every list read with the services ready and the account available:
    /// each flagged entry missing from the set is added alone, so a missed
    /// or failed addition is repaired without new generations for the others.
    func reconcileActiveApprovers(with list: [PairedDevice]) {
        guard canActivateApprovers else { return }
        guard approversLoaded else { return activateApproversIfNeeded() }
        for device in list where device.isApprover {
            activateMissingApprover(device.pairingID)
        }
    }

    /// Adds one pairing ID unless it is in the set already or its removal
    /// has begun. The Vault reads the revocation counter and the stored list
    /// itself, so an entry removed meanwhile is not added, and a removal that
    /// races the addition makes the Broker refuse it (ADR 0014 → Revocation).
    private func activateMissingApprover(_ pairingID: PairingID) {
        guard !revokedApprovers.contains(pairingID),
              vault.approvalRequests.activeApproverGeneration(pairingID: pairingID.rawValue) == nil else { return }
        trackPendingRequestsBeforeActivation()
        do {
            if !(try vault.activateStoredApprovers(only: pairingID)).isEmpty {
                environment.log(.approverActivated)
            }
        } catch {
            // The next list read tries again.
            environment.log(.approverActivationFailed)
        }
    }

    /// Eligibility is decided when a request is created, but the Broker's
    /// notification reaches the coordinator later, and can be merged into a
    /// later one. Tracking every pending request against the set as it is
    /// before an addition keeps a request the coordinator has not seen yet
    /// from going to an approver that joined after it.
    private func trackPendingRequestsBeforeActivation() {
        reconcileRemoteRequests()
    }
}
