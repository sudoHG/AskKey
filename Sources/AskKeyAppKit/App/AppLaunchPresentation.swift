import AppKit

struct AppLaunchPresentation: Equatable {
    let activationPolicy: NSApplication.ActivationPolicy
    let activatesApplication: Bool
    let hidesMainWindow: Bool

    static func plan(for source: AppLaunchSource) -> Self {
        switch source {
        case .active:
            return .init(
                activationPolicy: .regular,
                activatesApplication: true,
                hidesMainWindow: false
            )
        case .loginItem:
            return .init(
                activationPolicy: .accessory,
                activatesApplication: false,
                hidesMainWindow: true
            )
        }
    }

    func apply(
        setActivationPolicy: (NSApplication.ActivationPolicy) -> Void,
        activateApplication: () -> Void,
        hideMainWindow: () -> Void
    ) {
        setActivationPolicy(activationPolicy)
        if activatesApplication {
            activateApplication()
        } else if hidesMainWindow {
            hideMainWindow()
        }
    }
}
