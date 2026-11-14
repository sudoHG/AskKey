import AskKeyBroker
import AskKeyDevices
import AskKeyVault
import Foundation

/// What one remote request carries besides its response ID and deadline
/// (ADR 0014 → Encodings): the card's display, built from the same
/// App-derived data as the Mac's card (ADR 0008), the binding digest over
/// the Broker's own strings, and the offers under the current policy.
struct RemoteApprovalRequestContent: Equatable {
    let display: ApprovalRequestDisplay
    let bindingDigest: Data
    /// Before shortening; `ApprovalRequest.build` makes them Deny only when
    /// it shortened a field or the delivery metadata is unavailable.
    let offers: ApprovalOffers
    let timedDuration: UInt64

    /// Nil for anything but a read request with a display summary, which
    /// never leaves the Mac.
    init?(pending: BrokerPendingApproval, policy: AgentAccessPolicy) {
        let request = pending.request
        guard request.operation == .read, let summary = request.display,
              let digest = try? ApprovalBinding.digest(
                requestID: pending.requestID, operationID: request.operationID, credentialID: request.credentialID,
                targetID: request.targetID, operation: request.operation.rawValue, payloadDigest: request.payloadDigest,
                readProjectionDigest: request.readProjectionDigest, retransmissionDigest: request.retransmissionDigest
              ) else { return nil }
        let unavailable = summary.environmentVariables == nil || summary.temporaryFileVariables == nil
        display = ApprovalRequestDisplay(
            requesterName: request.callerName ?? "", purpose: request.callerPurpose ?? "",
            credentialName: pending.displayCredentialName, commandLine: summary.commandLine,
            workingDirectory: summary.workingDirectory ?? "", executableName: summary.executableBasename ?? "",
            deliveryRows: unavailable ? [] : Self.rows(summary), deliveryMetadataUnavailable: unavailable
        )
        bindingDigest = digest
        // End Timed Allow on Lock forbids remote timed grants whatever the
        // screen's state; otherwise the timed allowance is offered while
        // timed allowances are on, also while the Mac is locked (ADR 0014).
        let timed = policy.timedAllowanceEnabled && !policy.endTimedAllowancesOnLock
            && (1...120).contains(policy.timedAllowanceMinutes)
        offers = timed ? .all : .denyOrAllowOnce
        timedDuration = timed ? UInt64(policy.timedAllowanceMinutes * 60) : 0
    }

    /// The card's "Hands over" rows: for a bundle, one per delivered
    /// component in the metadata's order; otherwise the environment
    /// variables, then the temporary files, with an empty label.
    private static func rows(_ summary: BrokerApprovalOperationRequest.Display) -> [ApprovalDeliveryRow] {
        if let components = summary.components {
            return components.compactMap { component in
                switch component.delivery {
                case .environmentVariable(let variable):
                    return ApprovalDeliveryRow(kind: .environmentVariable, label: component.name, variable: variable)
                case .temporaryFile(let variable):
                    return ApprovalDeliveryRow(kind: .temporaryFile, label: component.name, variable: variable)
                case .none:
                    return nil
                }
            }
        }
        return (summary.environmentVariables ?? []).map { ApprovalDeliveryRow(kind: .environmentVariable, label: "", variable: $0) }
            + (summary.temporaryFileVariables ?? []).map { ApprovalDeliveryRow(kind: .temporaryFile, label: "", variable: $0) }
    }
}

/// How a request that left pending ended for an approver whose decision did
/// not move it (ADR 0014 → Closed messages).
enum RemoteClosedOutcome {
    static func outcome(for state: BrokerRequestState, decidedByApprover: Bool) -> ApprovalClosedOutcome {
        if decidedByApprover { return .decidedOnAnotherApprover }
        switch state {
        case .expired: return .expired
        case .cancelled: return .cancelled
        case .pending, .approved, .denied, .completed, .consumed, .outcomeUnknown: return .decidedOnMac
        }
    }
}
