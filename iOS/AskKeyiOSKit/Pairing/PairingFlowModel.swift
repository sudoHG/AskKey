import AskKeyDevices
import Foundation
import Observation

/// The responder's side of pairing (ADR 0013 → Pairing), from scanning the
/// Mac's QR code to the Mac's verified confirmation.
///
/// The code is shown only on the pairing screen, and only once the
/// messenger reports `showingCode`, which it does after a verified challenge
/// that matches the QR code and after CloudKit saved this iPhone's reveal.
/// The code never goes into a notification, a log or a test identifier.
@MainActor
@Observable
public final class PairingFlowModel: Identifiable {
    public enum Stage: Hashable, Sendable {
        case scanning
        /// The scanned code is being checked and the request created.
        case sending
        /// The request is sent; there is no code yet.
        case waitingForCode
        case code(PairingCodeDisplay)
        /// The Mac's verified confirmation arrived; the Mac is on the list.
        case paired(macName: String)
        case failed(PairingFailure)
    }

    public let id = UUID()
    public internal(set) var stage: Stage = .scanning
    public internal(set) var scanProblem: ScanProblem?
    public internal(set) var confirmProblem: ConfirmProblem?
    public internal(set) var isConfirming = false
    public internal(set) var camera: CameraAccess

    @ObservationIgnored private let messenger: DeviceMessenger
    @ObservationIgnored private let cameraAccess: any CameraAccessChecking
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private weak var host: AppModel?
    @ObservationIgnored private var joined = false
    /// The last refused text, so a code that stays in view is not handled again.
    @ObservationIgnored private var rejectedText: String?
    @ObservationIgnored private var finished = false

    /// How often the inbox is fetched while the pairing screen is open.
    static let pollInterval: TimeInterval = 1

    init(messenger: DeviceMessenger, camera: any CameraAccessChecking, deviceName: String, host: AppModel?) {
        self.messenger = messenger
        cameraAccess = camera
        self.camera = camera.access()
        self.deviceName = deviceName
        self.host = host
    }

    /// Whether closing the sheet would leave a session open; the sheet then
    /// offers only Cancel.
    public var isSessionOpen: Bool {
        switch stage {
        case .sending, .waitingForCode, .code: return true
        case .scanning, .paired, .failed: return false
        }
    }

    // MARK: Scanning

    /// Asks for camera access the first time the scanner opens.
    public func prepareCamera() async {
        camera = cameraAccess.access()
        guard camera == .notDetermined else { return }
        _ = await cameraAccess.requestAccess()
        camera = cameraAccess.access()
    }

    /// A QR code was read. Anything but a current Ask Key pairing code is
    /// refused with its own message, and the scanner keeps running.
    public func handleScanned(_ text: String) async {
        guard stage == .scanning, !finished, text != rejectedText else { return }
        stage = .sending
        scanProblem = nil
        do {
            try await messenger.joinPairing(scannedText: text, displayName: deviceName)
            joined = true
            // Cancel was chosen while the request was being created.
            guard !finished else {
                await messenger.cancelPairing()
                return
            }
            stage = .waitingForCode
            await refresh()
        } catch {
            stage = .scanning
            if error as? DeviceIdentityError == .unusable {
                host?.identityBecameUnusable()
                return
            }
            rejectedText = text
            scanProblem = ScanProblem(error)
            if scanProblem == .failed { AppLog.failure("Starting pairing", error) }
        }
    }

    public func dismissScanProblem() {
        scanProblem = nil
        rejectedText = nil
    }

    // MARK: Session

    /// Fetches the inbox about once a second while the screen is open; the
    /// messenger's timers withdraw a request that got no challenge within 60
    /// seconds and end the session at its expiry.
    public func run() async {
        while !Task.isCancelled, !finished {
            if joined { await refresh() }
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
        }
    }

    /// One fetch, then the screen follows the session's phase.
    func refresh() async {
        guard joined, !finished else { return }
        if let host {
            await host.processInbox()
        } else {
            _ = try? await messenger.poll()
        }
        // The timers also run when no fetch could, for example while iCloud
        // is unavailable, so a request without a challenge is still withdrawn.
        await messenger.advanceTimers()
        await followPhase()
    }

    private func followPhase() async {
        guard joined, !finished else { return }
        let phase = await messenger.pairingPhase
        switch phase {
        case nil, .waitingForChallenge?:
            stage = .waitingForCode
        case .showingCode(let code, let peer, let confirmed)?:
            stage = .code(PairingCodeDisplay(digits: code.formatted, macName: peer.displayName, confirmed: confirmed))
        case .paired(let peer, _)?:
            finished = true
            stage = .paired(macName: peer.displayName)
            host?.pairingSucceeded(with: peer.deviceID)
        case .ended(let reason)?:
            end(reason)
        default:
            // Initiator phases never occur on the responder.
            break
        }
    }

    private func end(_ reason: PairingEndReason) {
        finished = true
        switch reason {
        case .identityUnusable:
            host?.identityBecameUnusable()
        case .cancelled:
            // This side cancelled; the sheet is closing.
            break
        default:
            stage = .failed(PairingFailure(reason))
        }
    }

    /// Signs the confirmation with the approval key, which asks for Face ID
    /// or Touch ID every time with no passcode button. A cancelled or failed
    /// prompt sends nothing; the person can confirm again.
    public func confirm() async {
        guard case .code(let display) = stage, !display.confirmed, !isConfirming, !finished else { return }
        isConfirming = true
        confirmProblem = nil
        defer { isConfirming = false }
        let reason = String(localized: "pairing.confirm.reason \(display.macName)", bundle: .kit)
        do {
            try await messenger.confirmPairing(approvalReason: reason)
        } catch let error as DeviceIdentityError {
            switch error {
            case .authenticationCancelled: confirmProblem = .cancelled
            case .authenticationFailed: confirmProblem = .failed
            case .authenticationUnavailable: confirmProblem = .unavailable
            case .unusable, .secureEnclaveUnavailable, .keyCreationFailed:
                finished = true
                host?.identityBecameUnusable()
                return
            }
        } catch {
            // The session moved on (it ended, or this side already
            // confirmed); the phase below shows where it stands.
        }
        await followPhase()
    }

    /// Cancel: ends the session and tells the Mac, by a withdrawal when no
    /// challenge has arrived. It changes nothing once the Mac is on the list.
    func cancelIfOpen() async {
        guard joined, !finished else {
            finished = true
            return
        }
        finished = true
        await messenger.cancelPairing()
    }
}

/// What the pairing screen shows. Like `PairingCode`, its description and
/// mirror are redacted, so printing a stage never reveals the code.
public struct PairingCodeDisplay: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
                                  CustomReflectable {
    /// Two groups of three digits, `123 456`.
    public let digits: String
    public let macName: String
    /// This iPhone confirmed; the code stays until the Mac confirms too.
    public let confirmed: Bool

    public init(digits: String, macName: String, confirmed: Bool) {
        self.digits = digits
        self.macName = macName
        self.confirmed = confirmed
    }

    public var description: String { "PairingCodeDisplay(redacted, confirmed: \(confirmed))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum ScanProblem: Hashable, Sendable {
    /// Not an Ask Key pairing code at all.
    case notAPairingCode
    /// It starts like one but is damaged or from another version.
    case invalid
    case expired
    /// The code holds this iPhone's own keys or a paired device's.
    case keyConflict
    case deviceLimitReached
    case failed

    init(_ error: Error) {
        switch error {
        case PairingQRPayloadError.notAPairingCode: self = .notAPairingCode
        case PairingQRPayloadError.malformed: self = .invalid
        case PairingQRPayloadError.expired: self = .expired
        case DeviceMessengerError.keyConflict: self = .keyConflict
        case DeviceMessengerError.deviceLimitReached: self = .deviceLimitReached
        default: self = .failed
        }
    }
}

public enum ConfirmProblem: Hashable, Sendable {
    case cancelled
    case failed
    /// Face ID or Touch ID is off for Ask Key, or locked after failed attempts.
    case unavailable
}

public enum PairingFailure: Hashable, Sendable {
    /// No challenge within 60 seconds: the request was withdrawn. The person
    /// cancels on the Mac and enters no code there.
    case noChallenge
    case cancelledByMac
    case expired
    case conflictingChallenge
    case deviceLimitReached
    case keyConflict
    case ended

    init(_ reason: PairingEndReason) {
        switch reason {
        case .noChallenge: self = .noChallenge
        case .cancelledByPeer, .undoneByPeer: self = .cancelledByMac
        case .expired: self = .expired
        case .conflictingChallenge: self = .conflictingChallenge
        case .deviceLimitReached: self = .deviceLimitReached
        case .keyConflict: self = .keyConflict
        default: self = .ended
        }
    }
}
