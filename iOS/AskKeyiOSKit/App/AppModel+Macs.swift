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
