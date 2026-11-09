import AskKeyDevices
import Foundation

/// A list store in memory. Every save and load goes through the list's
/// serialization, as the keychain stores do.
public final class InMemoryPairedDeviceListStore: PairedDeviceListStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var failures = 0

    public init(_ list: PairedDeviceList = PairedDeviceList()) {
        stored = list.devices.isEmpty ? nil : try? list.serialized()
    }

    /// Makes the next `count` saves throw.
    public func failNextSaves(_ count: Int) {
        lock.withLock { failures = count }
    }

    public var storedBytes: Data? { lock.withLock { stored } }

    public func loadPairedDeviceList() throws -> PairedDeviceList {
        guard let data = lock.withLock({ stored }) else { return PairedDeviceList() }
        return try PairedDeviceList(serialized: data)
    }

    public func savePairedDeviceList(_ list: PairedDeviceList) throws {
        let data = try list.serialized()
        try lock.withLock {
            if failures > 0 {
                failures -= 1
                throw CocoaError(.fileWriteUnknown)
            }
            stored = data
        }
    }
}
