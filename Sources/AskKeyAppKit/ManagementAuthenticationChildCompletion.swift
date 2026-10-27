import Foundation

/// Resolves the race between parent cancellation and LocalAuthentication's reply.
/// Invalidation happens before the response/focus/exit handshake, exactly once.
@MainActor
final class ManagementAuthenticationChildCompletion {
    private var finished = false
    private let invalidate: () -> Void
    private let complete: (ManagementAuthenticationOutcome) -> Void

    init(invalidate: @escaping () -> Void, complete: @escaping (ManagementAuthenticationOutcome) -> Void) {
        self.invalidate = invalidate
        self.complete = complete
    }

    func finish(_ outcome: ManagementAuthenticationOutcome) {
        guard !finished else { return }
        finished = true
        if outcome == .cancelled { invalidate() }
        complete(outcome)
    }
}
