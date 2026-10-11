import Foundation

public enum CredentialAccessRecordPolicy {
    public static let maximumEntries = 256
    public static let retention: TimeInterval = 90 * 24 * 60 * 60
}

public struct CredentialAccessEvent: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case catalog, runtimeRead, create, modify, delete
    }

    public enum Result: String, Codable, Sendable {
        case allowed, denied, expired, failed, hiddenNameRejected
    }

    public let timestamp: Date
    public let credentialID: String?
    public let operation: Operation
    public let result: Result
    public let callerHint: String?
    public let declaredPurpose: String?
    public let executableBasename: String?

    public init(
        timestamp: Date,
        credentialID: String?,
        operation: Operation,
        result: Result,
        callerHint: String?,
        declaredPurpose: String?,
        executableBasename: String? = nil
    ) {
        self.timestamp = timestamp
        self.credentialID = credentialID
        self.operation = operation
        self.result = result
        self.callerHint = callerHint
        self.declaredPurpose = declaredPurpose
        self.executableBasename = executableBasename.map { ($0 as NSString).lastPathComponent }
    }
}
