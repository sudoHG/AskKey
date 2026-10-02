import AppKit

/// Derives the app activation policy from the one window that represents the
/// management experience. Other app-owned windows (approvals and menu bar
/// popovers) deliberately do not participate in this state.
struct ManagementDockPolicy {
    enum Event: Equatable {
        case launch(isActive: Bool)
        case applicationDidBecomeActive
        case applicationDidResignActive
        case managementWindowState(
            visible: Bool,
            miniaturized: Bool,
            key: Bool,
            applicationActive: Bool
        )
        case managementWindowOpenedByUser
    }

    private(set) var applicationActive = false
    private(set) var managementWindowVisible = false
    private(set) var managementWindowMiniaturized = false
    private(set) var managementWindowKey = false
    private(set) var activationPolicy: NSApplication.ActivationPolicy = .accessory

    var isManagementWindowForeground: Bool {
        applicationActive
            && managementWindowVisible
            && !managementWindowMiniaturized
            && managementWindowKey
    }

    /// Returns a policy only when the event changes the requested policy.
    /// Keeping this transition edge-triggered prevents duplicate AppKit
    /// notifications from repeatedly calling setActivationPolicy.
    @discardableResult
    mutating func handle(_ event: Event) -> NSApplication.ActivationPolicy? {
        switch event {
        case .launch(let isActive):
            applicationActive = isActive
            managementWindowVisible = isActive
            managementWindowMiniaturized = false
            managementWindowKey = isActive
        case .applicationDidBecomeActive:
            applicationActive = true
        case .applicationDidResignActive:
            applicationActive = false
        case .managementWindowState(
            let visible,
            let miniaturized,
            let key,
            let applicationActive
        ):
            self.applicationActive = applicationActive
            managementWindowVisible = visible
            managementWindowMiniaturized = miniaturized
            managementWindowKey = key
        case .managementWindowOpenedByUser:
            applicationActive = true
            managementWindowVisible = true
            managementWindowMiniaturized = false
            managementWindowKey = true
        }

        let next = isManagementWindowForeground ? NSApplication.ActivationPolicy.regular : .accessory
        guard next != activationPolicy else { return nil }
        activationPolicy = next
        return next
    }
}
