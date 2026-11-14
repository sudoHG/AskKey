import AppKit
import AskKeyVault
import Observation

extension AppDelegate {
    /// Creates and starts the device services (ADR 0013). Without a factory
    /// from the executable, the CloudKit backend exists only when
    /// `CloudKitGate` allows it; otherwise Devices reports "not configured"
    /// and no CloudKit object is created.
    func setupDeviceServices() {
        guard !ManagementAuthenticationSubprocess.isActive, DeviceServicesHost.coordinator == nil else { return }
        let backend: (any DeviceServicesBackend)?
        if let makeDeviceServices = AppRuntimeState.configuration.makeDeviceServices {
            backend = makeDeviceServices()
        } else {
            backend = CloudKitGate.currentProcessDecision().containerIdentifier
                .map { CloudKitDeviceServicesBackend(containerIdentifier: $0) }
        }
        let model = vault
        let registersForPushes = backend?.registersForRemoteNotifications == true
        let coordinator = DeviceCoordinator(environment: DeviceCoordinatorEnvironment(
            vault: .shared,
            backend: backend,
            inboxState: VaultDeviceInboxStateStore(vault: .shared),
            authenticate: { [weak model] reason in
                await model?.deviceOwnerAuthentication(reason: reason) ?? .cancelled
            },
            isManagementSessionActive: { [weak model] in
                guard let model else { return false }
                return model.hasManagementSession && !model.isLocked
            },
            // ADR 0014 → Mac App: only once this Mac has an identity, so a
            // Mac that never pairs registers no push.
            registerForRemoteNotifications: {
                if registersForPushes { NSApp.registerForRemoteNotifications() }
            }
        ))
        DeviceServicesHost.install(coordinator)
        guard backend != nil else { return }
        Vault.shared.setDeviceServicesStopHandler { [weak coordinator] in
            // The Vault already refuses every later write of these services.
            if Thread.isMainThread {
                MainActor.assumeIsolated { coordinator?.stopForLocalErase() }
            } else {
                DispatchQueue.main.async { coordinator?.stopForLocalErase() }
            }
        }
        observeManagementSessionForDevices()
        observeScreenLockForRemoteApproval()
        coordinator.start()
    }

    func stopDeviceServices() {
        for (center, token) in RemoteApprovalScreenObservers.tokens {
            center.removeObserver(token)
        }
        RemoteApprovalScreenObservers.tokens = []
        DeviceServicesHost.coordinator?.stop()
    }

    /// A request still waiting for its 20 seconds goes to the approvers at
    /// once when the screen locks or the session switches to another user
    /// (ADR 0014).
    private func observeScreenLockForRemoteApproval() {
        let observations: [(NotificationCenter, Notification.Name)] = [
            (DistributedNotificationCenter.default, .init("com.apple.screenIsLocked")),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification),
        ]
        for (center, name) in observations {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DeviceServicesHost.coordinator?.screenDidLock() }
            }
            RemoteApprovalScreenObservers.tokens.append((center, token))
        }
    }

    /// Locking management, its expiry or closing its window cancels an open
    /// pairing session (ADR 0013 → Pairing, step 6).
    private func observeManagementSessionForDevices() {
        withObservationTracking {
            _ = vault.hasManagementSession
            _ = vault.isLocked
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Observe again first: cancelling sends a message and suspends.
                self.observeManagementSessionForDevices()
                if !self.vault.hasManagementSession || self.vault.isLocked {
                    await DeviceServicesHost.coordinator?.managementSessionEnded()
                }
            }
        }
    }

    /// A push is only a hint to fetch this Mac's inbox; nothing in it is
    /// trusted or shown.
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        let hint = Dictionary(uniqueKeysWithValues: userInfo.map { (AnyHashable($0.key), $0.value) })
        DeviceServicesHost.coordinator?.handleRemoteNotification(hint)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("AskKey: remote notifications are unavailable; device messages are fetched by polling")
    }
}

/// The screen-lock observer of the remote approval schedule.
@MainActor
private enum RemoteApprovalScreenObservers {
    static var tokens: [(NotificationCenter, NSObjectProtocol)] = []
}
