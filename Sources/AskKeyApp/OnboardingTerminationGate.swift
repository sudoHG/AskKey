import AppKit

enum OnboardingTerminationGate {
#if DEBUG
    static var reply: (@MainActor (Bool) -> Void)?
#endif

    @MainActor
    static func shouldTerminate(
        hasInFlightWrite: Bool,
        arm: (@escaping () -> Void) -> Void
    ) -> NSApplication.TerminateReply {
        if hasInFlightWrite {
            arm {
#if DEBUG
                if let reply {
                    reply(true)
                    return
                }
#endif
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}
