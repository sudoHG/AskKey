import AskKeyDevices
import Foundation

/// The paired Macs on this iPhone: their names. Removal is in `AppModel`;
/// pairing is what makes this iPhone approve a Mac's requests (ADR 0014,
/// amended by #336).
extension AppModel {
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

/// The home's three tabs (ADR 0014 → iPhone app, Home, amended by #345).
public enum HomeTab: Hashable, Sendable, CaseIterable {
    /// Requests that can still be decided or wait for the Mac.
    case requests
    /// Requests this app verified, once they ended (#349).
    case history
    /// The paired Macs, pairing and this iPhone's own status.
    case macs
}

/// What the home shows besides the Macs: the Requests tab's rows and badge,
/// the notification authorization and the last delivery check.
extension AppModel {
    // MARK: Home

    /// The Requests tab's rows: requests that can still be decided or wait
    /// for the Mac. A finished request leaves the tab (decision 7 of #344);
    /// its open page keeps showing it until the person closes the page.
    public func activeRequests(at now: Date) -> [RequestCard] {
        requests.filter { !$0.phase(at: now).isFinished }
    }

    /// The Requests tab's badge: the requests that can still be decided.
    public func decidableRequestCount(at now: Date) -> Int {
        requests.filter { $0.phase(at: now) == .pending }.count
    }

    /// When the badge can next change without a new card: each undecided
    /// request's countdown end.
    public var decidableCountChanges: [Date] {
        requests.filter { $0.decision == nil && $0.outcome == nil && !$0.isGone }.map(\.countdownEnd).sorted()
    }

    /// The Macs whose requests this iPhone accepts.
    public var approvingMacCount: Int {
        pairedMacs.filter(\.isApprover).count
    }

    /// Notifications are off for Ask Key, so a request arrives unannounced.
    public var notificationsOff: Bool {
        notificationAuthorization == .denied
    }

    /// When this iPhone last answered a delivery check; nil before the first.
    public var lastDeliveryCheck: Date? {
        deliveryRecords.map(\.arrivedAt).max()
    }

    /// The scene became active: read the notification authorization again,
    /// since the person may have changed it in Settings, then collect the
    /// pushes and process the inbox.
    public func sceneBecameActive() async {
        await refreshNotificationAuthorization()
        await becameActive()
    }

    func refreshNotificationAuthorization() async {
        notificationAuthorization = await environment.notifications.authorization()
    }

    func readBiometryKind() {
        switch environment.biometry.status() {
        case .enrolled(let kind), .notEnrolled(let kind), .deniedForApp(let kind): biometryKind = kind
        case .passcodeNotSet, .unavailable: break
        }
    }
}
