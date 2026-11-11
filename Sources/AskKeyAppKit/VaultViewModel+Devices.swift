import Foundation

extension VaultViewModel {
    /// The model behind Settings → Devices (ADR 0013 → Mac App), over the
    /// App's one device coordinator. It lives as long as that coordinator,
    /// not as long as a view: Settings is rebuilt on every visit, and the
    /// section only receives this model. Nil in processes without device
    /// services; like a build without CloudKit, they show no Devices section.
    static var devicesSettingsModel: DevicesSettingsModel? {
        guard let coordinator = DeviceServicesHost.coordinator else { return nil }
        if let devicesModel, devicesModel.coordinator === coordinator { return devicesModel }
        let model = DevicesSettingsModel(coordinator: coordinator)
        devicesModel = model
        return model
    }

    private static var devicesModel: DevicesSettingsModel?
}
