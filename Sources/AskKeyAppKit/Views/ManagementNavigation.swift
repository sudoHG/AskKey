import Observation
import UserNotifications

@Observable
@MainActor
final class ManagementNavigation {
    var section: CredentialWorkspaceSection = .all
    var route: CredentialWorkspaceRoute = .library
    let interaction = ManagementInteractionState()
    private(set) var notificationRevision = 0
    private var pendingNotification: NotificationRoute?

    func handleNotificationResponse(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any],
        entryState: SettingsEntryState,
        openManagement: () -> Void
    ) {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        guard canLeaveCurrentPage(entryState: entryState) else {
            pendingNotification = nil
            openManagement()
            return
        }
        pendingNotification = NotificationRoute(userInfo: userInfo)
        // Keep the locked sidebar neutral, including when replacing an older route.
        section = .all
        route = .library
        notificationRevision += 1
        openManagement()
    }

    func applyPendingNotification(to vault: VaultViewModel) {
        guard let pendingNotification, !vault.isLocked, vault.hasManagementSession else { return }
        self.pendingNotification = nil
        guard canLeaveCurrentPage(entryState: vault.settingsEntryState) else { return }
        section = .all
        route = .library
        // Resolve only against fresh, authenticated metadata. Deleted and recycled
        // credentials, expired requests and unreadable stores fall back to the library.
        guard vault.reloadCredentials() else { return }
        switch pendingNotification {
        case .main:
            break
        case .pendingRequests:
            if vault.pendingApprovalCount > 0 { route = .pendingRequests }
        case .credential(let id):
            if vault.credentials.contains(where: { $0.id == id }) {
                route = .credentialDetail(id)
            }
        }
    }

    private func canLeaveCurrentPage(entryState: SettingsEntryState) -> Bool {
        guard entryState != .onboarding, entryState != .empty,
              !interaction.hasWorkInProgress else { return false }
        switch route {
        // These pages own drafts, onboarding, or nested confirmation state.
        // Protect the whole page, even before the first edit is made.
        case .editor, .fileImport, .templateChooser, .agentAccess, .settings:
            return false
        default:
            return true
        }
    }
}
