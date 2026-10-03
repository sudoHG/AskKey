enum LockedApprovalReminderDeliveryPolicy {
    static func marksNotificationPosted(
        for result: LockedApprovalReminderDeliveryResult
    ) -> Bool {
        result == .delivered
    }
}
