import AppKit
import AskKeyBroker

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
        queue: DispatchQueue = DispatchQueue(label: "com.sudohg.askkey.timed-allowance-session"),
        beginEndingEvent: @escaping @Sendable (Bool?) -> BrokerTimedAllowanceSessionEvent? = { _ in nil },
        updateSession: @escaping @Sendable (Bool, Bool, Bool, Bool?, UInt64?) -> Void
    ) {
        self.screenNotifications = screenNotifications
        self.workspaceNotifications = workspaceNotifications
        state = TimedAllowanceSessionState(screenState: screenState, queue: queue,
            beginEndingEvent: beginEndingEvent, updateSession: updateSession)
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
                    state.update(refreshScreen: true)
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
                state.update(sessionActive: true, refreshScreen: true)
            }
        ]
        // Register first, then enqueue the initial sample in the same FIFO as
        // notifications. Sampling and policy work never hold the event lock.
        state.update(refreshScreen: true)
    }

    @objc private func screenLocked(_ notification: Notification) {
        state.update(screenUnlocked: false, ending: true)
    }

    @objc private func screenUnlocked(_ notification: Notification) {
        state.update(refreshScreen: true)
    }

    deinit {
        if let distributed = screenNotifications as? DistributedNotificationCenter { distributed.removeObserver(self) }
        screenObservers.forEach(screenNotifications.removeObserver)
        workspaceObservers.forEach(workspaceNotifications.removeObserver)
    }
}

private final class TimedAllowanceSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let screenState: @Sendable () -> AgentApprovalScreenState
    private let beginEndingEvent: @Sendable (Bool?) -> BrokerTimedAllowanceSessionEvent?
    private let updateSession: @Sendable (Bool, Bool, Bool, Bool?, UInt64?) -> Void
    private var screenUnlocked = false
    private var sessionActive = true

    init(screenState: @escaping @Sendable () -> AgentApprovalScreenState, queue: DispatchQueue,
         beginEndingEvent: @escaping @Sendable (Bool?) -> BrokerTimedAllowanceSessionEvent?,
         updateSession: @escaping @Sendable (Bool, Bool, Bool, Bool?, UInt64?) -> Void) {
        self.screenState = screenState
        self.queue = queue
        self.beginEndingEvent = beginEndingEvent
        self.updateSession = updateSession
    }

    func update(screenUnlocked: Bool? = nil, sleeping: Bool? = nil, sessionActive: Bool? = nil,
                refreshScreen: Bool = false, ending: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let event = ending ? beginEndingEvent(sleeping) : nil
        queue.async { [self] in
            defer { event?.finish() }
            if let screenUnlocked { self.screenUnlocked = screenUnlocked }
            if let sessionActive { self.sessionActive = sessionActive }
            if refreshScreen { self.screenUnlocked = screenState() == .unlocked }
            // Sleep is a transition owned by the Broker, never an observer level.
            updateSession(self.screenUnlocked && self.sessionActive, ending, !self.sessionActive, sleeping,
                event?.sleepOffsetUpperBound)
        }
    }
}
