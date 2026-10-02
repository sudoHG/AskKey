import CryptoKit
import Foundation
import XCTest
@testable import AskKeyBroker
@testable import AskKeyCore

final class CredentialExpiryReminderTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSevenDayBoundaryUsesInjectedClock() {
        let justOutside = CredentialExpirySnapshot(
            id: "soon",
            expiresAt: now.addingTimeInterval(7 * day + 1)
        )
        let onBoundary = CredentialExpirySnapshot(
            id: "edge",
            expiresAt: now.addingTimeInterval(7 * day)
        )
        let inside = CredentialExpirySnapshot(
            id: "inside",
            expiresAt: now.addingTimeInterval(7 * day - 1)
        )

        XCTAssertEqual(
            CredentialExpiryReminderPolicy.work(snapshot: justOutside, ledger: nil, now: now),
            .schedule(id: "soon", at: now.addingTimeInterval(1))
        )
        XCTAssertEqual(
            CredentialExpiryReminderPolicy.work(snapshot: onBoundary, ledger: nil, now: now),
            .deliver(id: "edge")
        )
        XCTAssertEqual(
            CredentialExpiryReminderPolicy.work(snapshot: inside, ledger: nil, now: now),
            .deliver(id: "inside")
        )
    }

    func testExpiredAndMissingExpiryDoNotRemind() {
        XCTAssertNil(
            CredentialExpiryReminderPolicy.work(
                snapshot: .init(id: "due", expiresAt: now),
                ledger: nil,
                now: now
            )
        )
        XCTAssertNil(
            CredentialExpiryReminderPolicy.work(
                snapshot: .init(id: "none", expiresAt: nil),
                ledger: nil,
                now: now
            )
        )
    }

    func testReconcileCoversCreateChangeDeletePermissionFailureAndDuplicateLaunch() throws {
        let fixture = try makeVault()
        let created = try fixture.vault.createTextCredential(
            .init(
                name: "Synthetic Expiry",
                value: "SYNTHETIC-EXPIRY",
                permission: .ask,
                expiresAt: now.addingTimeInterval(10 * day)
            ),
            using: .allow
        )
        let recorder = ReminderRecorder()
        let ledger = ReminderLedgerStore()
        let scheduler = CredentialExpiryReminderScheduler(
            authorize: { .authorized },
            deliver: recorder.deliver,
            cancel: recorder.cancel,
            loadLedger: { ledger.entries },
            persistLedger: { ledger.entries = $0 }
        )

        scheduler.reconcile(
            snapshots: try fixture.vault.listCredentialExpirySnapshots(),
            now: now
        )
        XCTAssertEqual(recorder.deliveries, [
            .init(id: created.id, kind: .scheduled(now.addingTimeInterval(3 * day))),
        ])
        XCTAssertNil(scheduler.lastAuthorizationFailure)

        recorder.reset()
        scheduler.reconcile(
            snapshots: try fixture.vault.listCredentialExpirySnapshots(),
            now: now.addingTimeInterval(3 * day)
        )
        XCTAssertTrue(recorder.deliveries.isEmpty)
        XCTAssertTrue(recorder.cancels.isEmpty)

        recorder.reset()
        scheduler.reconcile(
            snapshots: try fixture.vault.listCredentialExpirySnapshots(),
            now: now.addingTimeInterval(3 * day + 30)
        )
        XCTAssertTrue(recorder.deliveries.isEmpty)
        XCTAssertTrue(recorder.cancels.isEmpty)

        try fixture.vault.updateCredentialMetadata(
            id: created.id,
            name: "Synthetic Expiry",
            usageInstructions: "",
            groupName: nil,
            permission: .ask,
            expiresAt: now.addingTimeInterval(20 * day),
            using: .allow
        )
        recorder.reset()
        scheduler.reconcile(
            snapshots: try fixture.vault.listCredentialExpirySnapshots(),
            now: now.addingTimeInterval(3 * day + 60)
        )
        XCTAssertEqual(recorder.deliveries, [
            .init(id: created.id, kind: .scheduled(now.addingTimeInterval(13 * day))),
        ])

        try fixture.vault.deleteTextCredential(id: created.id, using: .allow)
        recorder.reset()
        scheduler.reconcile(
            snapshots: try fixture.vault.listCredentialExpirySnapshots(),
            now: now.addingTimeInterval(4 * day)
        )
        XCTAssertEqual(recorder.cancels, [created.id])
        XCTAssertTrue(recorder.deliveries.isEmpty)
    }

    func testFirstSeenInsideTheLeadWindowDeliversOnce() {
        let snapshot = CredentialExpirySnapshot(
            id: "late-start",
            expiresAt: now.addingTimeInterval(2 * day)
        )
        let recorder = ReminderRecorder()
        let ledger = ReminderLedgerStore()
        let scheduler = CredentialExpiryReminderScheduler(
            authorize: { .authorized },
            deliver: recorder.deliver,
            cancel: recorder.cancel,
            loadLedger: { ledger.entries },
            persistLedger: { ledger.entries = $0 }
        )
        scheduler.reconcile(snapshots: [snapshot], now: now)
        XCTAssertEqual(recorder.deliveries, [
            .init(id: "late-start", kind: .immediate),
        ])
        recorder.reset()
        scheduler.reconcile(snapshots: [snapshot], now: now.addingTimeInterval(60))
        XCTAssertTrue(recorder.deliveries.isEmpty)
    }

    func testDeniedNotificationPermissionDoesNotMarkDeliveredAndReportsHonestly() throws {
        let snapshot = CredentialExpirySnapshot(
            id: "denied",
            expiresAt: now.addingTimeInterval(2 * day)
        )
        let recorder = ReminderRecorder()
        let ledger = ReminderLedgerStore()
        let scheduler = CredentialExpiryReminderScheduler(
            authorize: { .denied },
            deliver: recorder.deliver,
            cancel: recorder.cancel,
            loadLedger: { ledger.entries },
            persistLedger: { ledger.entries = $0 }
        )

        scheduler.reconcile(snapshots: [snapshot], now: now)
        XCTAssertTrue(recorder.deliveries.isEmpty)
        XCTAssertEqual(
            scheduler.lastAuthorizationFailure,
            CredentialExpiryReminderCopy.authorizationDeniedKey
        )
        XCTAssertTrue(ledger.entries.isEmpty)

        scheduler.replaceAuthorize { .authorized }
        scheduler.reconcile(snapshots: [snapshot], now: now)
        XCTAssertEqual(recorder.deliveries, [
            .init(id: "denied", kind: .immediate),
        ])
        XCTAssertNil(scheduler.lastAuthorizationFailure)
        XCTAssertEqual(ledger.entries["denied"]?.delivered, true)
    }

    func testDelayedDeliverFailureKeepsPendingAndRetriesThenDeduplicates() {
        let snapshot = CredentialExpirySnapshot(
            id: "async-fail",
            expiresAt: now.addingTimeInterval(2 * day)
        )
        var completions: [(Error?) -> Void] = []
        var deliveries: [CredentialExpiryReminderScheduler.Delivery] = []
        let ledger = ReminderLedgerStore()
        let scheduler = CredentialExpiryReminderScheduler(
            authorize: { .authorized },
            deliver: { delivery, completion in
                deliveries.append(delivery)
                completions.append(completion)
            },
            cancel: { _ in },
            loadLedger: { ledger.entries },
            persistLedger: { ledger.entries = $0 }
        )

        scheduler.reconcile(snapshots: [snapshot], now: now)
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertTrue(ledger.entries.isEmpty)

        completions[0](NSError(domain: "AskKey.test", code: 1))
        XCTAssertTrue(ledger.entries.isEmpty)
        XCTAssertEqual(
            scheduler.lastDeliveryFailure,
            CredentialExpiryReminderCopy.deliveryFailedKey
        )

        scheduler.reconcile(snapshots: [snapshot], now: now)
        XCTAssertEqual(deliveries.count, 2)
        completions[1](nil)
        XCTAssertEqual(ledger.entries["async-fail"]?.delivered, true)
        XCTAssertNil(scheduler.lastDeliveryFailure)

        scheduler.reconcile(snapshots: [snapshot], now: now.addingTimeInterval(60))
        XCTAssertEqual(deliveries.count, 2)
    }

    func testExpiryListingDoesNotNeedAManagementSession() throws {
        let fixture = try makeVault()
        let created = try fixture.vault.createTextCredential(
            .init(
                name: "Listed Without Session",
                value: "SYNTHETIC",
                permission: .ask,
                expiresAt: now.addingTimeInterval(9 * day)
            ),
            using: .allow
        )
        fixture.vault.endManagementSession()

        let snapshots = try fixture.vault.listCredentialExpirySnapshots()
        XCTAssertEqual(snapshots, [
            CredentialExpirySnapshot(id: created.id, expiresAt: now.addingTimeInterval(9 * day)),
        ])
    }

    func testChangingDefaultMinutesDoesNotExtendAnAlreadyGrantedWindow() throws {
        let start = Date(timeIntervalSince1970: 20_000)
        let machine = BrokerApprovalStateMachine(clock: { start }, authenticate: { _ in true })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyExpiryMinutes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(
            store: try VaultStore(path: directory.appendingPathComponent("vault.db").path),
            key: VaultCrypto.generateKey(),
            approvalRequests: machine
        )
        vault.updateDefaultTimedAllowanceMinutes(30)

        let first = try machine.submit(
            .init(
                operationID: "grant",
                credentialID: "credential-1",
                targetID: "credential-1",
                operation: .read,
                payloadDigest: String(repeating: "b", count: 64)
            ),
            now: start
        )
        XCTAssertEqual(
            try machine.decide(
                requestID: first.requestID,
                capability: first.capability,
                decision: .timedAllow(duration: nil),
                now: start
            ).state,
            .approved
        )

        vault.updateDefaultTimedAllowanceMinutes(120)
        XCTAssertEqual(
            try machine.submit(
                .init(
                    operationID: "still-old-window",
                    credentialID: "credential-1",
                    targetID: "credential-1",
                    operation: .read,
                    payloadDigest: String(repeating: "c", count: 64)
                ),
                now: start.addingTimeInterval(1_799)
            ).state,
            .approved
        )
        XCTAssertEqual(
            try machine.submit(
                .init(
                    operationID: "old-window-ended",
                    credentialID: "credential-1",
                    targetID: "credential-1",
                    operation: .read,
                    payloadDigest: String(repeating: "d", count: 64)
                ),
                now: start.addingTimeInterval(1_800)
            ).state,
            .pending
        )
    }

    private func makeVault() throws -> (vault: Vault, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyExpiry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(
            store: try VaultStore(path: directory.appendingPathComponent("vault.db").path),
            key: SymmetricKey(data: Data(repeating: 0x24, count: 32)),
            now: { self.now }
        )
        try vault.beginManagementSession(using: .allow)
        return (vault, directory)
    }
}

private final class ReminderLedgerStore: @unchecked Sendable {
    var entries: [String: ExpiryReminderLedgerEntry] = [:]
}

private final class ReminderRecorder: @unchecked Sendable {
    var deliveries: [CredentialExpiryReminderScheduler.Delivery] = []
    var cancels: [String] = []

    func deliver(
        _ delivery: CredentialExpiryReminderScheduler.Delivery,
        completion: @escaping (Error?) -> Void
    ) {
        deliveries.append(delivery)
        completion(nil)
    }

    func cancel(_ id: String) {
        cancels.append(id)
    }

    func reset() {
        deliveries = []
        cancels = []
    }
}
