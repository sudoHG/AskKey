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
            }
        ))
        DeviceServicesHost.install(coordinator)
        guard let backend else { return }
        Vault.shared.setDeviceServicesStopHandler { [weak coordinator] in
            // The Vault already refuses every later write of these services.
            if Thread.isMainThread {
                MainActor.assumeIsolated { coordinator?.stopForLocalErase() }
            } else {
                DispatchQueue.main.async { coordinator?.stopForLocalErase() }
            }
        }
        observeManagementSessionForDevices()
        if backend.registersForRemoteNotifications {
            NSApp.registerForRemoteNotifications()
        }
        coordinator.start()
    }

    func stopDeviceServices() {
        DeviceServicesHost.coordinator?.stop()
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
