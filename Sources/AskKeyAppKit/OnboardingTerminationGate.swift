import AppKit

enum OnboardingTerminationGate {
    @MainActor
    static func shouldTerminate(
        hasInFlightWrite: Bool,
        arm: (@escaping () -> Void) -> Void,
        reply: @escaping @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }
    ) -> NSApplication.TerminateReply {
        if hasInFlightWrite {
            arm {
                reply(true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}
