import Observation
import UserNotifications

@Observable
@MainActor
final class ManagementNavigation {
    var section: CredentialWorkspaceSection = .all
    var route: CredentialWorkspaceRoute = .library
    private(set) var notificationRevision = 0
    private var pendingNotification: NotificationRoute?

    func handleNotificationResponse(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any],
        openManagement: () -> Void
    ) {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
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
}
