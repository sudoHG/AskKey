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
            let replyName = activationReplyName
            let responder = LibraryInstanceActivationResponder()
            // Register before publishing the lock, including during early launch.
            libraryActivationObserver = center.addObserver(
                forName: name, object: namespace, queue: nil
            ) { notification in
                guard let request = notification.userInfo?["request"] as? String else { return }
                guard responder.acknowledge(request, reply: {
                    center.postNotificationName(
                        replyName, object: request,
                        userInfo: ["pid": ProcessInfo.processInfo.processIdentifier], deliverImmediately: true
                    )
                }) else { return }
                Task { @MainActor in libraryActivation.request() }
            }
            guard let lock = try responder.acquire(in: directory) else {
                let result = activateRunningLibrary(center: center, name: name, namespace: namespace)
                if let message = result.messageKey {
                    showLibraryInstanceFailure(message)
                }
                return false
            }
            libraryInstanceLock = lock
            return true
        } catch {
            let format = appLocalized("Ask Key could not open this credential library. Quit any other running copy, then try again. Details: %@")
            showLibraryInstanceFailure(String(format: format, error.localizedDescription))
            return false
        }
    }

    private static let activationReplyName = Notification.Name("com.sudohg.askkey.library-activated")

    private static func activateRunningLibrary(
        center: DistributedNotificationCenter, name: Notification.Name, namespace: String
    ) -> LibraryInstanceActivationResult {
        guard let executable = Bundle.main.executableURL else { return .unverifiedReply }
        let identity = LibraryInstanceApplicationIdentity(bundleIdentifier: Bundle.main.bundleIdentifier,
                                                         executableURL: executable)
        let request = UUID().uuidString
        let reply = LibraryInstanceActivationReply()
        let observer = center.addObserver(forName: activationReplyName, object: request, queue: nil) { note in
            if let pid = note.userInfo?["pid"] as? Int32 { reply.receive(pid) }
        }
        defer { center.removeObserver(observer) }
        let deadline = Date().addingTimeInterval(2)
        var result = LibraryInstanceActivationResult.noReply
        repeat {
            center.postNotificationName(name, object: namespace, userInfo: ["request": request], deliverImmediately: true)
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.2)))
            if let pid = reply.processIdentifier {
                let running = NSRunningApplication(processIdentifier: pid)
                result = LibraryInstanceActivationResult.classify(
                    identity: identity, bundleIdentifier: running?.bundleIdentifier,
                    executableURL: running?.executableURL, pid: pid,
                    ownPID: ProcessInfo.processInfo.processIdentifier
                )
                if result == .activated, let running {
                    NSApplication.shared.yieldActivation(to: running)
                    running.activate(options: [.activateAllWindows])
                    return .activated
                }
            }
        } while Date() < deadline
        return result
    }

    private static func showLibraryInstanceFailure(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = appLocalized("Ask Key could not open this library")
        alert.informativeText = appLocalized(reason)
        alert.runModal()
    }
}

enum LibraryInstanceActivationResult: Equatable {
    case activated, noReply, differentLocation, unverifiedReply

    static func classify(
        identity: LibraryInstanceApplicationIdentity, bundleIdentifier: String?,
        executableURL: URL?, pid: Int32, ownPID: Int32
    ) -> Self {
        if identity.matches(bundleIdentifier: bundleIdentifier, executableURL: executableURL,
                            pid: pid, ownPID: ownPID) {
            return .activated
        }
        if pid > 0, pid != ownPID, let bundleIdentifier,
           bundleIdentifier == identity.bundleIdentifier, let executableURL,
           identity.executableURL.resolvingSymlinksInPath().standardizedFileURL
            != executableURL.resolvingSymlinksInPath().standardizedFileURL {
            return .differentLocation
        }
        return .unverifiedReply
    }

    var messageKey: String? {
        switch self {
        case .activated: return nil
        case .noReply:
            return "Ask Key is already using this library, but the running instance did not respond. Try opening it again."
        case .differentLocation:
            return "Another copy of Ask Key is already running from a different location. Quit it, then open Ask Key from Applications."
        case .unverifiedReply:
            return "Ask Key could not verify the running copy. Quit any other running copy, then open Ask Key from Applications."
        }
    }
}
