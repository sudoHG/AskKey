import Foundation

@MainActor
final class SessionPolicy {
    typealias ScheduleTimer = @MainActor (Double, @escaping @Sendable (Timer) -> Void) -> Timer
    typealias EnqueueExpiration = @Sendable (@escaping @MainActor () -> Void) -> Void

    private var lockTimer: Timer?
    private var activeGeneration: UUID?
    private var expirationAction: (@MainActor () -> Void)?
    private var activeTimeout: Double = 0
    /// The timer came due while idle expiry was held; the policy restarts its
    /// full timeout when the last hold is released.
    private var expiryDeferred = false
    private let scheduleTimer: ScheduleTimer
    private let enqueueExpiration: EnqueueExpiration

    init(
        scheduleTimer: @escaping ScheduleTimer = { timeout, callback in
            // Common modes keep the idle lock running during menus and modal pickers.
            let timer = Timer(timeInterval: timeout, repeats: false, block: callback)
            RunLoop.main.add(timer, forMode: .common)
            return timer
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
        activeTimeout = timeout
        let enqueueExpiration = enqueueExpiration
        lockTimer = scheduleTimer(timeout) { [weak self] _ in
            enqueueExpiration { [weak self] in
                guard let self, self.activeGeneration == generation else { return }
                if Self.idleExpiryHolds > 0 {
                    // An open pairing sheet keeps the session from expiring for idleness.
                    self.expiryDeferred = true
                    Self.deferredPolicies.append(WeakSessionPolicy(policy: self))
                    return
                }
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
        expiryDeferred = false
    }

    // MARK: Idle expiry holds

    private struct WeakSessionPolicy {
        weak var policy: SessionPolicy?
    }

    private static var idleExpiryHolds = 0
    private static var deferredPolicies: [WeakSessionPolicy] = []

    /// While any hold is open, no session policy expires for idleness; a
    /// timer that comes due waits. Releasing the last hold restarts each
    /// waiting policy's full timeout, the normal expiry. An open pairing
    /// sheet holds one until its session ends or the sheet closes (ADR 0013
    /// → Pairing, step 6).
    static func holdIdleExpiry() -> SessionExpiryHold {
        idleExpiryHolds += 1
        return SessionExpiryHold()
    }

    fileprivate static func releaseIdleExpiryHold() {
        idleExpiryHolds = max(0, idleExpiryHolds - 1)
        guard idleExpiryHolds == 0 else { return }
        let waiting = deferredPolicies.compactMap(\.policy)
        deferredPolicies = []
        for policy in waiting where policy.expiryDeferred {
            guard let action = policy.expirationAction else { continue }
            policy.renew(timeout: policy.activeTimeout, onExpire: action)
        }
    }

    static var isIdleExpiryHeld: Bool { idleExpiryHolds > 0 }
}

/// One hold on idle expiry; `release()` is idempotent.
@MainActor
final class SessionExpiryHold {
    private var released = false

    fileprivate init() {}

    func release() {
        guard !released else { return }
        released = true
        SessionPolicy.releaseIdleExpiryHold()
    }
}
