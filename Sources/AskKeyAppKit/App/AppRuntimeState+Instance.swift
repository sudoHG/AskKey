import AppKit
import AskKeyVault

extension AppRuntimeState {
    /// Runs before SwiftUI constructs any view model, Vault or Broker service.
    static func acquireLibraryInstance() -> Bool {
        if ManagementAuthenticationSubprocess.isActive { return true }
        do {
            try VaultConfiguration.validateRuntimeIsolation()
            let directory = VaultConfiguration.daemonSocketURL.deletingLastPathComponent()
            let namespace = directory.resolvingSymlinksInPath().standardizedFileURL.path
            let center = DistributedNotificationCenter.default()
            let name = Notification.Name("com.sudohg.askkey.activate-library")
            guard let lock = try LibraryInstanceLock.acquire(in: directory) else {
                center.postNotificationName(name, object: namespace, userInfo: nil, deliverImmediately: true)
                return false
            }
            libraryInstanceLock = lock
            libraryActivationObserver = center.addObserver(
                forName: name, object: namespace, queue: .main
            ) { _ in
                Task { @MainActor in
                    libraryActivation.request()
                }
            }
            return true
        } catch {
            NSLog("AskKey: cannot acquire the library instance lock: \(error.localizedDescription)")
            return false
        }
    }
}
