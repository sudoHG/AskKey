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

    /// A launch kept in the menu bar hides management now and once more on
    /// the next run-loop turn, unless something opened management in between
    /// (a queued second-instance activation, a notification or a reopen).
    func apply(
        setActivationPolicy: (NSApplication.ActivationPolicy) -> Void,
        activateApplication: () -> Void,
        hideMainWindow: @escaping () -> Void,
        isStillInBackground: @escaping () -> Bool = { true },
        nextTurn: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        setActivationPolicy(activationPolicy)
        if activatesApplication {
            activateApplication()
        } else if hidesMainWindow {
            hideMainWindow()
            nextTurn {
                guard isStillInBackground() else { return }
                hideMainWindow()
            }
        }
    }
}
