import AppKit

/// Listens without changing pending approvals or the management session.
final class TimedAllowanceSessionObserver: NSObject {
    private let screenNotifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private var screenObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private let state: TimedAllowanceSessionState

    init(
        screenNotifications: NotificationCenter,
        workspaceNotifications: NotificationCenter,
        screenState: @escaping @Sendable () -> AgentApprovalScreenState,
        updateSession: @escaping @Sendable (Bool, Bool, Bool) -> Void
    ) {
        self.screenNotifications = screenNotifications
        self.workspaceNotifications = workspaceNotifications
        state = TimedAllowanceSessionState(screenState: screenState, updateSession: updateSession)
        super.init()
        let state = self.state
        if let distributed = screenNotifications as? DistributedNotificationCenter {
            distributed.addObserver(self, selector: #selector(screenLocked(_:)),
                name: .init("com.apple.screenIsLocked"), object: nil, suspensionBehavior: .deliverImmediately)
            distributed.addObserver(self, selector: #selector(screenUnlocked(_:)),
                name: .init("com.apple.screenIsUnlocked"), object: nil, suspensionBehavior: .deliverImmediately)
        } else {
            screenObservers = [
                screenNotifications.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { _ in
                    state.update(screenUnlocked: false, ending: true)
                },
                screenNotifications.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil) { _ in
                    state.update(sleeping: false, refreshScreen: true)
                }
            ]
        }
        workspaceObservers = [
            workspaceNotifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
                state.update(sleeping: true, ending: true)
            },
            workspaceNotifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
                state.update(sleeping: false, refreshScreen: true)
            },
            workspaceNotifications.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil) { _ in
                state.update(sessionActive: false, ending: true)
            },
            workspaceNotifications.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: nil) { _ in
                state.update(sleeping: false, sessionActive: true, refreshScreen: true)
            }
        ]
        // Register first, then sample under the event lock to avoid missing a
        // lock between the initial screen-state read and observer installation.
        state.update(refreshScreen: true)
    }

    @objc private func screenLocked(_ notification: Notification) {
        state.update(screenUnlocked: false, ending: true)
    }

    @objc private func screenUnlocked(_ notification: Notification) {
        state.update(sleeping: false, refreshScreen: true)
    }

    deinit {
        if let distributed = screenNotifications as? DistributedNotificationCenter { distributed.removeObserver(self) }
        screenObservers.forEach(screenNotifications.removeObserver)
        workspaceObservers.forEach(workspaceNotifications.removeObserver)
    }
}

private final class TimedAllowanceSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private let screenState: @Sendable () -> AgentApprovalScreenState
    private let updateSession: @Sendable (Bool, Bool, Bool) -> Void
    private var screenUnlocked = false
    private var sleeping = false
    private var sessionActive = true

    init(screenState: @escaping @Sendable () -> AgentApprovalScreenState,
         updateSession: @escaping @Sendable (Bool, Bool, Bool) -> Void) {
        self.screenState = screenState
        self.updateSession = updateSession
    }

    func update(screenUnlocked: Bool? = nil, sleeping: Bool? = nil, sessionActive: Bool? = nil,
                refreshScreen: Bool = false, ending: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        if let screenUnlocked { self.screenUnlocked = screenUnlocked }
        if let sleeping { self.sleeping = sleeping }
        if let sessionActive { self.sessionActive = sessionActive }
        if refreshScreen { self.screenUnlocked = screenState() == .unlocked }
        let suspended = self.sleeping || !self.sessionActive
        updateSession(self.screenUnlocked && !suspended, ending, suspended)
    }
}
