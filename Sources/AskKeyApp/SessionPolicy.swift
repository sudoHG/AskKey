import Foundation

@MainActor
final class SessionPolicy {
    typealias ScheduleTimer = @MainActor (Double, @escaping @Sendable (Timer) -> Void) -> Timer
    typealias EnqueueExpiration = @Sendable (@escaping @MainActor () -> Void) -> Void

    private var lockTimer: Timer?
    private var activeGeneration: UUID?
    private var expirationAction: (@MainActor () -> Void)?
    private let scheduleTimer: ScheduleTimer
    private let enqueueExpiration: EnqueueExpiration

    init(
        scheduleTimer: @escaping ScheduleTimer = { timeout, callback in
            Timer.scheduledTimer(withTimeInterval: timeout, repeats: false, block: callback)
        },
        enqueueExpiration: @escaping EnqueueExpiration = { callback in
            Task { @MainActor in callback() }
        }
    ) {
        self.scheduleTimer = scheduleTimer
        self.enqueueExpiration = enqueueExpiration
    }

    deinit {
        guard let timer = lockTimer else { return }
        if Thread.isMainThread {
            timer.invalidate()
        } else {
            // A final reference may be released off-actor. Timers installed by
            // this MainActor policy must still be invalidated on the main thread.
            DispatchQueue.main.async { timer.invalidate() }
        }
    }

    func renew(timeout: Double, onExpire: @escaping @MainActor () -> Void) {
        cancel()
        let generation = UUID()
        activeGeneration = generation
        expirationAction = onExpire
        let enqueueExpiration = enqueueExpiration
        lockTimer = scheduleTimer(timeout) { [weak self] _ in
            enqueueExpiration { [weak self] in
                guard let self, self.activeGeneration == generation else { return }
                let action = self.expirationAction
                // Retire this generation before calling client code, which may renew.
                self.cancel()
                action?()
            }
        }
    }

    func cancel() {
        activeGeneration = nil
        lockTimer?.invalidate()
        lockTimer = nil
        expirationAction = nil
    }
}
