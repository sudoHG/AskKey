import AskKeyDevices
import Foundation

public enum AppStage: Hashable, Sendable {
    case starting
    case welcome
    case ready
    /// A stored key no longer works; only a reset helps.
    case unusableIdentity
}

public enum WelcomeStep: Hashable, Sendable {
    case intro
    case checking
    case failed(WelcomeFailure)
}

/// Each failed welcome check, with its own explanation.
public enum WelcomeFailure: Hashable, Sendable {
    case noSecureEnclave
    case biometryNotEnrolled(BiometryKind)
    case passcodeNotSet
    case biometryDenied(BiometryKind)
    case noBiometry
    /// This build carries no CloudKit container.
    case cloudNotConfigured
    case iCloudSignedOut
    case iCloudRestricted
    case iCloudUnavailable
    case keyCreationFailed
    case keychainFailed
    /// CloudKit could not be reached, for example before the person allowed
    /// the app to use wireless data.
    case networkUnavailable
    case iCloudFailed
}

/// Why paired Macs cannot reach this iPhone right now. The list is kept.
public enum AccountNotice: Hashable, Sendable {
    case signedOut
    case restricted
    case unavailable
}

public enum ListNotice: Hashable, Sendable {
    /// Removed here; `macWasTold` tells whether the unpair notice was sent.
    case removed(name: String, macWasTold: Bool)
    /// The Mac removed this iPhone and its unpair notice arrived.
    case removedByMac(name: String)
    case removalFailed
}

public struct PairedMacRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let pairedAt: Date
    /// Nil until the first delivery check from that Mac arrived.
    public let lastReachedAt: Date?
    /// This iPhone accepts approval requests from this Mac.
    public let isApprover: Bool

    public init(id: String, name: String, pairedAt: Date, lastReachedAt: Date?, isApprover: Bool = false) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastReachedAt = lastReachedAt
        self.isApprover = isApprover
    }

    init(_ device: PairedDevice) {
        self.init(id: device.deviceID.text, name: device.displayName, pairedAt: device.pairedAt,
                  lastReachedAt: device.lastReachedAt, isApprover: device.isApprover)
    }
}

/// A newly paired Mac whose proposed name another Mac already had.
public struct RenamePrompt: Identifiable, Hashable, Sendable {
    public var id: String { macID }
    public let macID: String
    /// The name the Mac proposed, which another Mac already has.
    public let takenName: String
    /// The numbered name it got instead.
    public let newName: String
}

/// Why a rename was refused.
public enum RenameProblem: Hashable, Sendable {
    case empty
    /// Another Mac already has this name.
    case duplicate(String)
    case failed
}
