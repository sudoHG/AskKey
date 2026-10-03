import Darwin
import Dispatch
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class FileDeliveryLifetimeTests: RuntimeApprovalBoundaryTestSupport {
    func testSlowMaterializationRejectsAnAlreadyExpiredFileWithoutAnApprovalScope() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeySlowExpiredFile-\(UUID().uuidString)")
        let clock = ApprovalBoundaryClock()
        let schedule = ApprovalBoundaryCleanupSchedule()
        let manager = try FileDeliveryManager(
            rootURL: root, ttl: 30, now: { clock.now }, schedule: { schedule.record($0, $1) },
            synchronizeFile: { descriptor in
                guard Darwin.fsync(descriptor) == 0 else { return -1 }
                clock.advance(30)
                return 0
            }
        )
        defer { manager.cleanupAll(); try? FileManager.default.removeItem(at: root) }
        var unexpectedlyReturned: FileDelivery?
        XCTAssertThrowsError(unexpectedlyReturned = try manager.materialize(
            credentialID: "allowed-without-approval", bytes: Data("synthetic-file".utf8)
        ))
        withExtendedLifetime(unexpectedlyReturned) {
            XCTAssertTrue(ApprovalBoundaryHarness.payloadFiles(in: root).isEmpty)
        }
    }
    func testSlowMaterializationSchedulesOnlyTheRemainingAbsoluteFileLifetime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeySlowRemainingFile-\(UUID().uuidString)")
        let clock = ApprovalBoundaryClock()
        let start = clock.now
        let schedule = ApprovalBoundaryCleanupSchedule()
        let manager = try FileDeliveryManager(
            rootURL: root, ttl: 30, now: { clock.now }, schedule: { schedule.record($0, $1) },
            synchronizeFile: { descriptor in
                guard Darwin.fsync(descriptor) == 0 else { return -1 }
                clock.advance(10)
                return 0
            }
        )
        defer { manager.cleanupAll(); try? FileManager.default.removeItem(at: root) }
        let delivery = try manager.materialize(
            credentialID: "allowed-without-approval", bytes: Data("synthetic-file".utf8)
        )
        XCTAssertEqual(delivery.expiresAt, start.addingTimeInterval(30))
        XCTAssertEqual(schedule.delays, [20], "fsync must consume, rather than restart, the file lifetime")
        clock.advance(20)
        schedule.fire()
        XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.url.path))
    }
}
