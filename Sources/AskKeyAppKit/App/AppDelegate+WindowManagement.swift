import SwiftUI

extension AppDelegate {
    func setupWindowBehavior() {
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

    func ensureManagementWindow() {
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
                .ignoresSafeArea(.container, edges: .top)
        )
        window.title = vault.brandName
        managementWindow = window
    }

    func hideManagementWindow() {
        managementWindow?.orderOut(nil)
        syncManagementWindowDockState()
    }

    private func isManagementWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "settings"
    }

    private func handleManagementDockEvent(_ event: ManagementDockPolicy.Event) {
        // A Touch ID prompt takes focus briefly; keep the Dock state as it was.
        guard !ManagementAuthenticationSubprocess.isActive,
              !ManagementAuthenticationRunner.isPromptShowing else { return }
        if isApplyingDockPolicy {
            scheduleManagementDockStateRefresh()
            return
        }
        _ = managementDockPolicy.handle(event)
        scheduleManagementDockPolicyApplication()
    }

    private func syncManagementWindowDockState() {
        guard !ManagementAuthenticationSubprocess.isActive,
              !ManagementAuthenticationRunner.isPromptShowing else { return }
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

    func scheduleManagementDockPolicyApplication() {
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
}
