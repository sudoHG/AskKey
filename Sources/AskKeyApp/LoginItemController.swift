import ServiceManagement

struct LoginItemController {
    private let isEnabledImpl: () -> Bool
    private let setEnabledImpl: (Bool) throws -> Void

    var isEnabled: Bool { isEnabledImpl() }

    func setEnabled(_ isEnabled: Bool) throws {
        try setEnabledImpl(isEnabled)
        NotificationCenter.default.post(name: .askKeyOrdinaryBackupSettingsDidChange, object: nil)
    }

    init(
        isEnabled: @escaping () -> Bool = {
            SMAppService.mainApp.status == .enabled
        },
        setEnabled: @escaping (Bool) throws -> Void = { isEnabled in
            let service = SMAppService.mainApp
            if isEnabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        }
    ) {
        isEnabledImpl = isEnabled
        setEnabledImpl = setEnabled
    }
}
