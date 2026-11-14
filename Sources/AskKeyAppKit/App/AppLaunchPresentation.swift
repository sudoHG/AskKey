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
        case .loginItem, .helper:
            // Menu bar only. Approval prompts are their own panels and still
            // appear; the menu bar icon or opening Ask Key again brings the
            // management window.
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
