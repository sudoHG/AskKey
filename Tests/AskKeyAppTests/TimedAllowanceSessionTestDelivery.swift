import AppKit
import AskKeyBroker
@testable import AskKeyAppKit

let timedAllowanceSessionTestQueue = DispatchQueue(label: "askkey.tests.timed-session-delivery")

/// Existing policy scenarios wait for the real asynchronous observer before
/// their next assertion. Concurrency tests use ordinary centers instead.
final class TimedAllowanceTestNotificationCenter: NotificationCenter, @unchecked Sendable {
    override func post(name: Notification.Name, object: Any?, userInfo: [AnyHashable: Any]? = nil) {
        super.post(name: name, object: object, userInfo: userInfo)
        timedAllowanceSessionTestQueue.sync {}
    }
}

final class SynchronousTimedAllowanceSessionObserver {
    private let observer: TimedAllowanceSessionObserver

    init(screenNotifications: NotificationCenter, workspaceNotifications: NotificationCenter,
         screenState: @escaping @Sendable () -> AgentApprovalScreenState,
         updateSession: @escaping @Sendable (Bool, Bool, Bool, Bool?, UInt64?) -> Void) {
        observer = TimedAllowanceSessionObserver(screenNotifications: screenNotifications,
            workspaceNotifications: workspaceNotifications, screenState: screenState,
            queue: timedAllowanceSessionTestQueue, updateSession: updateSession)
        timedAllowanceSessionTestQueue.sync {}
    }
}
