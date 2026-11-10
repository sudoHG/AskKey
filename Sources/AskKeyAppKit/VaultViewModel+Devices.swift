import Foundation

extension VaultViewModel {
    /// The model behind Settings → Devices (ADR 0013 → Mac App), over the
    /// App's one device coordinator. Nil in processes without device
    /// services; like a build without CloudKit, they show no Devices section.
    static func makeDevicesSettingsModel() -> DevicesSettingsModel? {
        DeviceServicesHost.coordinator.map(DevicesSettingsModel.init(coordinator:))
    }
}
