import AskKeyDevices
import Foundation

/// What a card shows of a verified approval request. Every text arrives
/// preformatted (ADR 0014 → Encodings): the card shows it as plain text,
/// never quoted, escaped or turned into links again. It never holds a
/// credential value.
public struct RequestDisplay: Hashable, Sendable {
    /// Empty when absent; the card then says "Local Agent".
    public let requesterName: String
    public let purpose: String
    public let credentialName: String
    public let commandLine: String
    public let workingDirectory: String
    public let executableName: String
    public let deliveryRows: [ApprovalDeliveryRow]
    /// The Mac card's "this run will be refused" case.
    public let deliveryMetadataUnavailable: Bool
    public let shortened: ApprovalShortenedFields
    public let offers: ApprovalOffers
    /// Seconds of the timed allowance when it is offered; otherwise 0.
    public let timedDuration: UInt64

    public init(requesterName: String, purpose: String, credentialName: String, commandLine: String,
                workingDirectory: String, executableName: String, deliveryRows: [ApprovalDeliveryRow],
                deliveryMetadataUnavailable: Bool = false, shortened: ApprovalShortenedFields = [],
                offers: ApprovalOffers = .denyOrAllowOnce, timedDuration: UInt64 = 0) {
        self.requesterName = requesterName
        self.purpose = purpose
        self.credentialName = credentialName
        self.commandLine = commandLine
        self.workingDirectory = workingDirectory
        self.executableName = executableName
        self.deliveryRows = deliveryRows
        self.deliveryMetadataUnavailable = deliveryMetadataUnavailable
        self.shortened = shortened
        self.offers = offers
        self.timedDuration = timedDuration
    }

    init(_ request: ApprovalRequest) {
        self.init(requesterName: request.requesterName, purpose: request.purpose, credentialName: request.credentialName,
                  commandLine: request.commandLine, workingDirectory: request.workingDirectory,
                  executableName: request.executableName, deliveryRows: request.deliveryRows,
                  deliveryMetadataUnavailable: request.deliveryMetadataUnavailable, shortened: request.shortened,
                  offers: request.offers, timedDuration: request.timedDuration)
    }

    /// The command on one line, middle-truncated at 160 characters as the
    /// Mac's display summary does.
    public var commandSummary: String {
        guard commandLine.count > 160 else { return commandLine }
        return String(commandLine.prefix(80)) + "…" + String(commandLine.suffix(79))
    }

    /// The decision buttons in the card's order: Deny, Allow Once, then the
    /// timed allowance, each only when offered.
    public var offeredCodes: [ApprovalDecisionCode] {
        ApprovalDecisionCode.allCases.filter { offers.contains($0) }
    }
}

/// How the Mac said a request ended (ADR 0014 → Approval closed).
public enum RequestOutcome: Hashable, Sendable {
    case allowedOnce
    /// The seconds the Mac granted, at most the offered duration.
    case allowedTimed(seconds: UInt64)
    case denied
    case decidedOnMac
    case decidedElsewhere
    case expired
    case cancelled
    /// The Mac verified the decision but could not apply it as signed.
    case notApplied

    init?(_ closed: StoredClosed) {
        switch closed.closedOutcome {
        case .applied?:
            switch closed.appliedCode.flatMap(ApprovalDecisionCode.init(rawValue:)) {
            case .deny?: self = .denied
            case .allowOnce?: self = .allowedOnce
            case .timedAllowance?: self = .allowedTimed(seconds: closed.appliedDuration)
            case nil: return nil
            }
        case .decidedOnMac?: self = .decidedOnMac
        case .decidedOnAnotherApprover?: self = .decidedElsewhere
        case .expired?: self = .expired
        case .cancelled?: self = .cancelled
        case .notApplied?: self = .notApplied
        case nil: return nil
        }
    }
}

/// Where a card stands.
public enum RequestPhase: Hashable, Sendable {
    /// Waiting for the person's decision.
    case pending
    /// The decision is stored and CloudKit has not saved it yet.
    case sending(ApprovalDecisionCode)
    /// CloudKit saved the decision; the Mac has not closed the request yet.
    case waiting(ApprovalDecisionCode)
    case closed(RequestOutcome)
    /// The countdown ended without a closed message: check the Mac.
    case timedOut(decided: ApprovalDecisionCode?)
    /// The Mac App restarted, so the request no longer exists there.
    case gone

    /// Nothing more can be decided.
    public var isFinished: Bool {
        switch self {
        case .pending, .sending, .waiting: return false
        case .closed, .timedOut, .gone: return true
        }
    }
}

/// One request card: the verified display, the iPhone's own name for the
/// Mac (the request carries no Mac name), and the stored progress.
public struct RequestCard: Identifiable, Hashable, Sendable {
    /// The request's record name.
    public let id: String
    public let macID: String
    public let macName: String
    public let macPairedAt: Date
    public let display: RequestDisplay
    public let countdownEnd: Date
    public let decision: ApprovalDecisionCode?
    /// CloudKit saved the decision at least once.
    public let isSent: Bool
    public let outcome: RequestOutcome?
    public let isGone: Bool

    public init(id: String, macID: String, macName: String, macPairedAt: Date, display: RequestDisplay,
                countdownEnd: Date, decision: ApprovalDecisionCode? = nil, isSent: Bool = false,
                outcome: RequestOutcome? = nil, isGone: Bool = false) {
        self.id = id
        self.macID = macID
        self.macName = macName
        self.macPairedAt = macPairedAt
        self.display = display
        self.countdownEnd = countdownEnd
        self.decision = decision
        self.isSent = isSent
        self.outcome = outcome
        self.isGone = isGone
    }

    public func phase(at now: Date) -> RequestPhase {
        if let outcome { return .closed(outcome) }
        if isGone { return .gone }
        if now >= countdownEnd { return .timedOut(decided: decision) }
        guard let decision else { return .pending }
        return isSent ? .waiting(decision) : .sending(decision)
    }

    /// Whole seconds left on this iPhone's countdown.
    public func secondsLeft(at now: Date) -> Int {
        max(0, Int(countdownEnd.timeIntervalSince(now).rounded(.up)))
    }
}

/// Why a decision was not sent. Nothing was sent in every case.
public enum DecisionProblem: Hashable, Sendable {
    case cancelled
    case failed
    /// Face ID or Touch ID is off for Ask Key, or locked after failed attempts.
    case unavailable
    /// iCloud is signed out, restricted, changed or unreachable.
    case account
    case timeUp
    /// The decision could not be stored before its first send.
    case storage
    case other
}

/// The request a tapped notification opened.
public struct OpenedRequest: Identifiable, Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}
