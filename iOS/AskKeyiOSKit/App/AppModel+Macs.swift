import AskKeyDevices
import Foundation

/// The approver confirmation while its sheet is open (ADR 0014 → Approvers, step 2).
public struct ApproverConfirmationFlow: Identifiable, Hashable, Sendable {
    public enum Stage: Hashable, Sendable {
        /// Typing the code.
        case entering
        /// Checking, and the Face ID prompt.
        case confirming
        /// Sealed; sending until CloudKit saves it.
        case sending
        /// Saved, and this iPhone's approval flag for the Mac is set.
        case sent
    }

    public var id: String { macID }
    public let macID: String
    public let macName: String
    public internal(set) var stage: Stage = .entering
    public internal(set) var problem: ApproverProblem?

    public init(macID: String, macName: String, stage: Stage = .entering, problem: ApproverProblem? = nil) {
        self.macID = macID
        self.macName = macName
        self.stage = stage
        self.problem = problem
    }
}

/// Why the confirmation is not sent, or not sent yet.
public enum ApproverProblem: Hashable, Sendable {
    /// Not exactly six digits once white space is removed; nothing was sent.
    case invalidCode
    case cancelled
    case failed
    case unavailable
    case account
    /// CloudKit has not saved it yet; it is tried again.
    case retrying
    /// It expired before CloudKit saved it.
    case notSent
    case other
}

/// The paired Macs on this iPhone: names, approval, removal.
extension AppModel {
    // MARK: Approval

    public func startApproverConfirmation(macID: String) {
        guard stage == .ready, approverConfirmation == nil, let row = pairedMacs.first(where: { $0.id == macID }) else {
            return
        }
        approverConfirmation = ApproverConfirmationFlow(macID: row.id, macName: row.name)
    }

    /// Closes the sheet. A confirmation already sealed is still sent, and
    /// the flag set once CloudKit saves it.
    public func closeApproverConfirmation() {
        approverConfirmation = nil
    }

    /// **Approve Requests from This Mac**: sends nothing unless exactly six
    /// ASCII digits remain once white space is removed; then signs the code
    /// proof with the approval key (Face ID), and once CloudKit saved the
    /// confirmation, sets this iPhone's approval flag for the Mac. It
    /// cannot learn whether the Mac accepted.
    public func confirmApprover(typed text: String) async {
        guard let flow = approverConfirmation, flow.stage == .entering, let services,
              let mac = DeviceID(text: flow.macID) else { return }
        guard let code = ApproverCode(typed: text) else {
            approverConfirmation?.problem = .invalidCode
            return
        }
        approverConfirmation?.problem = nil
        approverConfirmation?.stage = .confirming
        func stop(_ problem: ApproverProblem) {
            guard approverConfirmation?.macID == flow.macID else { return }
            approverConfirmation?.stage = .entering
            approverConfirmation?.problem = problem
        }
        guard await accountAllowsSending(services) else { return stop(.account) }
        guard let list = try? await services.registry.list(), self.services === services,
              let entry = list.device(mac) else { return stop(.other) }
        let sealed: SealedDeviceMessage
        do {
            isAuthenticating = true
            defer { isAuthenticating = false }
            let reason = String(localized: "approver.reason \(entry.displayName)", bundle: .kit)
            sealed = try await services.sealer.sealApproverConfirmation(code, to: entry, approvalReason: reason)
        } catch let error as DeviceIdentityError {
            switch error {
            case .authenticationCancelled: return stop(.cancelled)
            case .authenticationFailed: return stop(.failed)
            case .authenticationUnavailable: return stop(.unavailable)
            case .unusable, .secureEnclaveUnavailable, .keyCreationFailed:
                approverConfirmation = nil
                return identityBecameUnusable()
            }
        } catch {
            AppLog.failure("Sealing an approver confirmation", error)
            return stop(.other)
        }
        // The prompt may have outlasted the Mac's entry.
        guard self.services === services, let after = try? await services.registry.list(),
              after.device(mac)?.pairingID == entry.pairingID else { return stop(.other) }
        outbox[sealed.envelope.recordName] = OutgoingMessage(envelope: sealed.envelope,
                                                             purpose: .confirmation(mac: mac, pairingID: entry.pairingID))
        if approverConfirmation?.macID == flow.macID { approverConfirmation?.stage = .sending }
        await sendDueMessages()
    }

    /// CloudKit saved the confirmation: the flag for that pairing is set.
    func confirmationSaved(mac: DeviceID, pairingID: PairingID, services: DeviceServices) async {
        do {
            guard try await services.registry.apply(.setApprover(mac, pairingID: pairingID, enabled: true)) == .applied else {
                if approverConfirmation?.macID == mac.text { approverConfirmation = nil }
                return
            }
            revokedPairings.remove(pairingID)
            if approverConfirmation?.macID == mac.text {
                approverConfirmation?.stage = .sent
                approverConfirmation?.problem = nil
            }
        } catch {
            AppLog.failure("Setting the approval flag", error)
            if approverConfirmation?.macID == mac.text {
                approverConfirmation?.stage = .entering
                approverConfirmation?.problem = .other
            }
        }
        await refreshList()
    }

    /// **Stop Approving for This Mac**: its requests are refused at once,
    /// and its cards, stored decisions and notifications are dropped before
    /// the flag is cleared. The Mac's own setting changes on the Mac.
    public func stopApproving(macID: String) async {
        guard let services, let mac = DeviceID(text: macID),
              let entry = try? await services.registry.list().device(mac) else { return }
        revokedPairings.insert(entry.pairingID)
        dropApprovals(forMac: macID)
        do {
            try await services.registry.apply(.setApprover(mac, pairingID: entry.pairingID, enabled: false))
        } catch {
            AppLog.failure("Clearing the approval flag", error)
        }
        await refreshList()
    }

    // MARK: Names

    /// Renames a Mac on this iPhone. Names stay unique: a name another Mac
    /// already has is refused.
    public func renameMac(id: String, to name: String) async -> RenameProblem? {
        guard let services, let mac = DeviceID(text: id) else { return .failed }
        let cleaned = DeviceDisplayName.clean(name)
        guard !cleaned.isEmpty else { return .empty }
        do {
            let list = try await services.registry.list()
            guard let entry = list.device(mac) else { return .failed }
            if list.devices.contains(where: { $0.deviceID != mac && Self.sameName($0.displayName, cleaned) }) {
                return .duplicate(cleaned)
            }
            guard try await services.registry.apply(.rename(mac, pairingID: entry.pairingID, displayName: cleaned)) == .applied
            else { return .failed }
        } catch {
            AppLog.failure("Renaming a Mac", error)
            return .failed
        }
        if renamePrompt?.macID == id { renamePrompt = nil }
        await refreshList()
        return nil
    }

    /// Keeps Mac names unique: a Mac whose name another Mac already has
    /// gets the first free numbered name, such as "Studio Mac 2". Macs this
    /// iPhone saw before keep their names; among the rest, the one paired
    /// first does. A Mac that pairing just added then asks to be renamed.
    /// Returns whether any name changed.
    func makeNamesUnique(in list: PairedDeviceList, services: DeviceServices) async -> Bool {
        let seen = seenPairings
        seenPairings = Set(list.devices.map(\.pairingID))
        func isNew(_ device: PairedDevice) -> Bool { seen.map { !$0.contains(device.pairingID) } ?? false }
        var taken: [String] = []
        var renames: [(device: PairedDevice, name: String)] = []
        for device in list.devices.sorted(by: {
            (isNew($0) ? 1 : 0, $0.pairedAt, $0.deviceID) < (isNew($1) ? 1 : 0, $1.pairedAt, $1.deviceID)
        }) {
            if taken.contains(where: { Self.sameName($0, device.displayName) }) {
                let name = Self.numberedName(device.displayName, taken: taken)
                renames.append((device, name))
                taken.append(name)
            } else {
                taken.append(device.displayName)
            }
        }
        var changed = false
        for (device, name) in renames {
            do {
                let outcome = try await services.registry.apply(.rename(device.deviceID, pairingID: device.pairingID,
                                                                        displayName: name))
                guard outcome == .applied else { continue }
                changed = true
                if isNew(device) {
                    renamePrompt = RenamePrompt(macID: device.deviceID.text, takenName: device.displayName, newName: name)
                }
            } catch {
                AppLog.failure("Renaming a Mac", error)
            }
        }
        return changed
    }

    static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
    }

    /// `name` with the first free number, shortened so the number survives
    /// the display-name limits.
    static func numberedName(_ name: String, taken: [String]) -> String {
        var number = 2
        while true {
            let suffix = " \(number)"
            var base = name
            var candidate = DeviceDisplayName.clean(base + suffix)
            while !candidate.hasSuffix(suffix), !base.isEmpty {
                base.removeLast()
                candidate = DeviceDisplayName.clean(base + suffix)
            }
            if !taken.contains(where: { sameName($0, candidate) }) { return candidate }
            number += 1
        }
    }
}
