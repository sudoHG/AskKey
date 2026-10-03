import Foundation

public enum BrokerLimits {
    public static let maximumFrameBytes = 64 * 1024
    public static let maximumResponseBytes = 64 * 1024
    public static let maximumFieldBytes = 4 * 1024
    public static let maximumConnections = 16
    public static let maximumRequestsPerConnection = 32
    public static let maximumConcurrentRequests = 8
    public static let maximumRuntimeReceiptCount = 65_536
    public static let maximumQueuedRequests = 32
    public static let maximumPendingApprovalRequests = 64
    public static let maximumRetainedRequestStates = 256
    public static let readDeadline: TimeInterval = 2
    public static let requestDeadline: TimeInterval = 1
    public static let writeDeadline: TimeInterval = 2
}
