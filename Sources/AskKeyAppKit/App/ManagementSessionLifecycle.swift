@MainActor
struct ManagementSessionLifecycle {
    enum Event: Equatable {
        case popoverDisappeared
        case applicationDeactivated
        case windowClosed(identifier: String?)
    }

    private let endManagementSession: () -> Void

    init(endManagementSession: @escaping () -> Void) {
        self.endManagementSession = endManagementSession
    }

    func handle(_ event: Event) {
        guard event == .windowClosed(identifier: "settings") else { return }
        endManagementSession()
    }
}
