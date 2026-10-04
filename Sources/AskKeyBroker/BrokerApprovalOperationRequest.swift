import Foundation

public struct BrokerApprovalOperationRequest: Equatable, Sendable {
    public let operationID: String
    public let credentialID: String
    public let targetID: String
    public let operation: BrokerApprovalOperation
    public let payloadDigest: String
    public let retransmissionDigest: String?
    public let credentialName: String?
    public let callerName: String?
    public let callerPurpose: String?
    /// App-derived presentation only; never an authorization input.
    public let display: Display?

    public init(
        operationID: String,
        credentialID: String,
        targetID: String,
        operation: BrokerApprovalOperation,
        payloadDigest: String,
        credentialName: String? = nil,
        callerName: String? = nil,
        callerPurpose: String? = nil,
        retransmissionDigest: String? = nil,
        display: Display? = nil
    ) {
        self.operationID = operationID
        self.credentialID = credentialID
        self.targetID = targetID
        self.operation = operation
        self.payloadDigest = payloadDigest
        self.retransmissionDigest = retransmissionDigest
        self.credentialName = credentialName
        self.callerName = callerName
        self.callerPurpose = callerPurpose
        self.display = display
    }

    // Preserve equality over exactly the pre-existing fields. Display changes
    // must not affect submission, retransmission or consumption.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.operationID == rhs.operationID
            && lhs.credentialID == rhs.credentialID
            && lhs.targetID == rhs.targetID
            && lhs.operation == rhs.operation
            && lhs.payloadDigest == rhs.payloadDigest
            && lhs.retransmissionDigest == rhs.retransmissionDigest
            && lhs.credentialName == rhs.credentialName
            && lhs.callerName == rhs.callerName
            && lhs.callerPurpose == rhs.callerPurpose
    }

    public struct Display: Equatable, Sendable {
        public let commandLine: String
        public let workingDirectory: String?
        public let executableBasename: String?
        /// Nil means the mapping is unavailable without decrypting values.
        public let environmentVariables: [String]?
        public let temporaryFileVariables: [String]?

        public var commandSummary: String {
            guard commandLine.count > 160 else { return commandLine }
            return String(commandLine.prefix(80)) + "…" + String(commandLine.suffix(79))
        }

        public init(
            commandLine: String,
            workingDirectory: String?,
            executableBasename: String?,
            environmentVariables: [String]?,
            temporaryFileVariables: [String]?
        ) {
            self.commandLine = commandLine
            self.workingDirectory = workingDirectory
            self.executableBasename = executableBasename
            self.environmentVariables = environmentVariables
            self.temporaryFileVariables = temporaryFileVariables
        }
    }
}

extension BrokerApprovalOperationRequest {
    func matchesForConsumption(_ other: BrokerApprovalOperationRequest) -> Bool {
        operationID == other.operationID
            && credentialID == other.credentialID
            && targetID == other.targetID
            && operation == other.operation
            && credentialName == other.credentialName
            && callerName == other.callerName
            && callerPurpose == other.callerPurpose
            && retransmissionDigest == other.retransmissionDigest
            && constantTimeEqual(payloadDigest, other.payloadDigest)
    }

    func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
