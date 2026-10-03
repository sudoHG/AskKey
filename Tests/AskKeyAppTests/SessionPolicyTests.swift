import Foundation
import XCTest
@testable import AskKeyAppKit

@MainActor
final class SessionPolicyTests: AskKeyAppTestCase {
    func testQueuedExpirationCannotExpireRenewedSession() async throws {
        let scheduler = ManualSessionScheduler()
        let policy = scheduler.makePolicy()
        defer { policy.cancel() }
        var expiredSessions: [String] = []

        policy.renew(timeout: 3_600) { expiredSessions.append("old") }
        try XCTUnwrap(scheduler.timers.first).fire()
        let queuedExpiration = try XCTUnwrap(scheduler.tasks.snapshot().first)
        // No suspension before renew: the real Timer has fired, but its
        // MainActor task cannot run until this synchronous segment yields.
        policy.renew(timeout: 3_600) { expiredSessions.append("new") }

        await queuedExpiration.value

        XCTAssertTrue(expiredSessions.isEmpty, "The old timeout must not end the renewed session")
        let currentTimer = try XCTUnwrap(scheduler.timers.last)
        XCTAssertTrue(currentTimer.isValid)
        currentTimer.fire()
        try await XCTUnwrap(scheduler.tasks.snapshot().last).value
        XCTAssertEqual(expiredSessions, ["new"])
    }

    func testQueuedExpirationCannotExpireSessionStartedAfterCancellation() async throws {
        let scheduler = ManualSessionScheduler()
        let policy = scheduler.makePolicy()
        defer { policy.cancel() }
        var expiredSessions: [String] = []

        policy.renew(timeout: 3_600) { expiredSessions.append("old") }
        try XCTUnwrap(scheduler.timers.last).fire()
        let oldExpiration = try XCTUnwrap(scheduler.tasks.snapshot().last)
        policy.cancel()
        policy.renew(timeout: 3_600) { expiredSessions.append("new") }

        await oldExpiration.value

        XCTAssertTrue(expiredSessions.isEmpty)
        try XCTUnwrap(scheduler.timers.last).fire()
        try await XCTUnwrap(scheduler.tasks.snapshot().last).value
        XCTAssertEqual(expiredSessions, ["new"])
    }

    func testCancellationDiscardsQueuedExpirationAndReleasesItsResources() async throws {
        let scheduler = ManualSessionScheduler()
        let policy = scheduler.makePolicy()
        defer { policy.cancel() }
        var payload: ExpirationPayload? = ExpirationPayload()
        weak var retainedPayload = payload
        var expirationCount = 0

        policy.renew(timeout: 3_600) { [payload] in
            payload?.expirationCount += 1
            expirationCount += 1
        }
        payload = nil
        XCTAssertNotNil(retainedPayload)
        var timer: Timer? = try XCTUnwrap(scheduler.timers.last)
        weak var retainedTimer = timer
        timer?.fire()
        let queuedExpiration = try XCTUnwrap(scheduler.tasks.snapshot().last)

        policy.cancel()

        XCTAssertFalse(try XCTUnwrap(timer).isValid)
        XCTAssertNil(retainedPayload, "Cancellation must release the action before its queued task runs")
        scheduler.releaseRecordedTimers()
        timer = nil
        XCTAssertNil(retainedTimer, "A live policy must not retain its cancelled timer")
        await queuedExpiration.value
        XCTAssertEqual(expirationCount, 0)
    }

    func testPolicyReleaseInvalidatesTimerAndReleasesActionBeforeQueuedWorkRuns() async throws {
        for fireBeforeRelease in [false, true] {
            let scheduler = ManualSessionScheduler()
            var policy: SessionPolicy? = scheduler.makePolicy()
            weak var retainedPolicy = policy
            var payload: ExpirationPayload? = ExpirationPayload()
            weak var retainedPayload = payload
            var expirationCount = 0

            policy?.renew(timeout: 3_600) { [payload] in
                payload?.expirationCount += 1
                expirationCount += 1
            }
            payload = nil
            var timer: Timer? = try XCTUnwrap(scheduler.timers.last)
            weak var retainedTimer = timer
            if fireBeforeRelease { timer?.fire() }
            let queuedExpirations = scheduler.tasks.snapshot()
            XCTAssertEqual(queuedExpirations.count, fireBeforeRelease ? 1 : 0)

            policy = nil

            XCTAssertNil(retainedPolicy)
            XCTAssertFalse(try XCTUnwrap(timer).isValid)
            XCTAssertNil(retainedPayload)
            scheduler.releaseRecordedTimers()
            timer = nil
            XCTAssertNil(retainedTimer)
            for task in queuedExpirations { await task.value }
            XCTAssertEqual(expirationCount, 0)
        }
    }

    func testCurrentExpirationRunsOnlyOnceWhenTimerIsFiredRepeatedly() async throws {
        let scheduler = ManualSessionScheduler()
        let policy = scheduler.makePolicy()
        defer { policy.cancel() }
        var expirationCount = 0
        policy.renew(timeout: 3_600) { expirationCount += 1 }
        let timer = try XCTUnwrap(scheduler.timers.last)

        timer.fire()
        timer.fire()
        let queuedExpirations = scheduler.tasks.snapshot()
        XCTAssertFalse(queuedExpirations.isEmpty)
        for task in queuedExpirations { await task.value }

        XCTAssertEqual(expirationCount, 1)
        XCTAssertFalse(timer.isValid)
        timer.fire()
        for task in scheduler.tasks.snapshot() { await task.value }
        XCTAssertEqual(expirationCount, 1)
    }

    func testBackgroundPolicyReleaseSchedulesTimerCleanupOnMainThread() async throws {
        XCTAssertTrue(Thread.isMainThread)
        let scheduler = ManualSessionScheduler()
        var policy: SessionPolicy? = scheduler.makePolicy()
        weak var retainedPolicy = policy
        var payload: ExpirationPayload? = ExpirationPayload()
        weak var retainedPayload = payload
        policy?.renew(timeout: 3_600) { [payload] in payload?.expirationCount += 1 }
        payload = nil
        let timer = try XCTUnwrap(scheduler.timers.last)
        let transferredOwner = BackgroundPolicyOwner(try XCTUnwrap(policy))
        policy = nil
        let released = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            transferredOwner.release()
            released.signal()
        }
        // Keep the main thread occupied until the background deinit returns:
        // its queued timer cleanup cannot run before the following assertions.
        XCTAssertEqual(released.wait(timeout: .now() + 2), .success)
        XCTAssertNil(retainedPolicy)
        XCTAssertNil(retainedPayload)
        XCTAssertTrue(timer.isValid, "Background deinit must not invalidate a main-thread timer directly")

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertFalse(timer.isValid)
                continuation.resume()
            }
        }
    }

    func testExpirationCanRenewWithoutClearingTheNewSession() async throws {
        let scheduler = ManualSessionScheduler()
        let policy = scheduler.makePolicy()
        defer { policy.cancel() }
        var expiredSessions: [String] = []
        policy.renew(timeout: 3_600) { [weak policy] in
            expiredSessions.append("first")
            policy?.renew(timeout: 3_600) { expiredSessions.append("second") }
        }
        let firstTimer = try XCTUnwrap(scheduler.timers.last)
        firstTimer.fire()
        try await XCTUnwrap(scheduler.tasks.snapshot().last).value

        XCTAssertEqual(expiredSessions, ["first"])
        XCTAssertEqual(scheduler.timers.count, 2)
        let renewedTimer = try XCTUnwrap(scheduler.timers.last)
        XCTAssertTrue(renewedTimer.isValid)
        renewedTimer.fire()
        try await XCTUnwrap(scheduler.tasks.snapshot().last).value
        XCTAssertEqual(expiredSessions, ["first", "second"])
        XCTAssertFalse(renewedTimer.isValid)
    }

    func testRepeatedRenewAndCancelRejectsOlderExpirationsDeliveredInReverseOrder() async throws {
        let scheduler = ManualSessionScheduler(holdExpirations: true)
        let policy = scheduler.makePolicy()
        defer {
            policy.cancel()
            scheduler.tasks.releaseAll()
        }
        var expiredSessions: [String] = []
        for index in 0..<3 {
            policy.renew(timeout: 3_600) { expiredSessions.append("old-\(index)") }
            try XCTUnwrap(scheduler.timers.last).fire()
            if index.isMultiple(of: 2) { policy.cancel() }
        }
        policy.renew(timeout: 3_600) { expiredSessions.append("current") }
        try XCTUnwrap(scheduler.timers.last).fire()
        let queuedExpirations = scheduler.tasks.snapshot()
        XCTAssertEqual(queuedExpirations.count, 4)
        guard queuedExpirations.count == 4 else { return }

        for index in [2, 1, 0] {
            scheduler.tasks.release(at: index)
            await queuedExpirations[index].value
            XCTAssertTrue(expiredSessions.isEmpty)
        }
        scheduler.tasks.release(at: 3)
        await queuedExpirations[3].value
        XCTAssertEqual(expiredSessions, ["current"])
    }
}

@MainActor
private final class ManualSessionScheduler {
    private(set) var timers: [Timer] = []
    let tasks: ExpirationTaskRecorder

    init(holdExpirations: Bool = false) {
        tasks = ExpirationTaskRecorder(holdExpirations: holdExpirations)
    }

    func releaseRecordedTimers() {
        timers.removeAll()
    }

    func makePolicy() -> SessionPolicy {
        SessionPolicy(
            scheduleTimer: { [self] timeout, callback in
                let timer = Timer(timeInterval: timeout, repeats: false, block: callback)
                timers.append(timer)
                return timer
            },
            enqueueExpiration: { [tasks] callback in
                tasks.enqueue(callback)
            }
        )
    }
}

private final class ExpirationTaskRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let holdExpirations: Bool
    private var tasks: [Task<Void, Never>] = []
    private var releases: [AsyncStream<Void>.Continuation] = []

    init(holdExpirations: Bool) {
        self.holdExpirations = holdExpirations
    }

    func enqueue(_ callback: @escaping @MainActor () -> Void) {
        let (permit, release) = AsyncStream<Void>.makeStream()
        let holdExpirations = holdExpirations
        let task = Task { @MainActor in
            if holdExpirations {
                for await _ in permit { break }
            }
            callback()
        }
        lock.lock()
        tasks.append(task)
        releases.append(release)
        lock.unlock()
        if !holdExpirations { release.finish() }
    }

    func snapshot() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        return tasks
    }

    func release(at index: Int) {
        lock.lock()
        let release = releases[index]
        lock.unlock()
        release.yield(())
        release.finish()
    }

    func releaseAll() {
        lock.lock()
        let releases = releases
        lock.unlock()
        for release in releases {
            release.yield(())
            release.finish()
        }
    }
}

private final class ExpirationPayload {
    var expirationCount = 0
}

/// Ownership is initialized on MainActor, then handed to one background block.
/// No thread reads the stored reference while that block releases it.
private final class BackgroundPolicyOwner: @unchecked Sendable {
    private var policy: SessionPolicy?

    init(_ policy: SessionPolicy) {
        self.policy = policy
    }

    func release() {
        policy = nil
    }
}
