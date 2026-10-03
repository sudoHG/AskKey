import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class FileCleanupVisibilityTests: AskKeyAppTestCase {
    func testBackgroundCleanupReturnsWhileMainActorWaitsAndEventuallyShowsError() async throws {
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyAppBackgroundCleanupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remover = AppFailingOnceRemover()
        let manager = try FileDeliveryManager(
            rootURL: root,
            ttl: 300,
            retryDelay: 60,
            removeItem: { try remover.remove($0) }
        )
        defer { manager.cleanupAll() }
        let delivery = try manager.materialize(credentialID: "credential", bytes: Data([1]))
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "com.sudohg.askkey.tests.background-cleanup").async {
            ready.signal()
            guard release.wait(timeout: .now() + 3) == .success else {
                finished.signal()
                return
            }
            delivery.finish()
            finished.signal()
        }

        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        release.signal()
        // Deliberately hold the main actor: cleanup must not synchronously wait
        // for its error notification to be handled by the UI.
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: delivery.url.path))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while viewModel.errorMessage == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            viewModel.errorMessage,
            "Ask Key could not remove a temporary credential file. It will keep retrying."
        )
    }

    func testReleasedObservationStopsReceivingCleanupFailures() {
        let center = NotificationCenter()
        var received = 0
        var observation: FileCleanupFailureObservation? = FileCleanupFailureObservation(center: center) {
            received += 1
        }
        withExtendedLifetime(observation) {
            center.post(name: .askKeyFileDeliveryCleanupFailed, object: nil)
        }
        XCTAssertEqual(received, 1)

        observation = nil
        center.post(name: .askKeyFileDeliveryCleanupFailed, object: nil)
        XCTAssertEqual(received, 1)
    }

    func testDeletionFailureAppearsInTheAppErrorStateWhileRetryContinues() throws {
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyAppCleanupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remover = AppFailingOnceRemover()
        let manager = try FileDeliveryManager(
            rootURL: root,
            ttl: 300,
            retryDelay: 0.01,
            removeItem: { try remover.remove($0) }
        )
        let delivery = try manager.materialize(credentialID: "credential", bytes: Data([1]))

        delivery.finish()

        XCTAssertEqual(
            viewModel.errorMessage,
            "Ask Key could not remove a temporary credential file. It will keep retrying."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: delivery.url.path))
    }
}

private final class AppFailingOnceRemover: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func remove(_ url: URL) throws {
        lock.lock()
        let fail = shouldFail
        shouldFail = false
        lock.unlock()
        if fail { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)) }
        try FileManager.default.removeItem(at: url)
    }
}
