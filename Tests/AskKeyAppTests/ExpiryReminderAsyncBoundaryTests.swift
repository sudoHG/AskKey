import CryptoKit
import Foundation
import UserNotifications
import XCTest
@testable import AskKeyApp
@testable import AskKeyCore

private struct SyntheticNotificationAddFailure: Error {}

@MainActor
final class ExpiryReminderAsyncBoundaryTests: AskKeyAppTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOutOfOrderPermissionCompletionDoesNotDeliverDeletedCredential() async throws {
        let fixture = try makeVault()
        let created = try insertSoonExpiringCredential(in: fixture.vault, name: "Stale Callback")
        let port = DeferredExpiryReminderNotificationPort()
        let defaults = makeDefaults()
        let controller = makeController(vault: fixture.vault, defaults: defaults, port: port)

        controller.reconcile()
        try fixture.vault.deleteTextCredential(id: created.id, using: .allow)
        controller.reconcile()
        XCTAssertEqual(port.statusCompletions.count, 2)

        port.statusCompletions[1](.authorized)
        await yieldMain()
        port.statusCompletions[0](.authorized)
        await yieldMain()

        XCTAssertEqual(try fixture.vault.listCredentialExpirySnapshots().count, 0)
        XCTAssertEqual(port.addedIDs, [])
        XCTAssertTrue(loadLedger(defaults).isEmpty)
    }

    func testAuthorizationDialogDeleteDoesNotDeliverDeletedCredential() async throws {
        let fixture = try makeVault()
        let created = try insertSoonExpiringCredential(in: fixture.vault, name: "Auth Delete")
        let port = DeferredExpiryReminderNotificationPort()
        let defaults = makeDefaults()
        let controller = makeController(vault: fixture.vault, defaults: defaults, port: port)

        controller.reconcile()
        XCTAssertEqual(port.statusCompletions.count, 1)
        port.statusCompletions[0](.notDetermined)
        await yieldMain()
        XCTAssertEqual(port.authCompletions.count, 1)

        try fixture.vault.deleteTextCredential(id: created.id, using: .allow)
        controller.reconcile()
        port.statusCompletions[1](.notDetermined)
        await yieldMain()

        port.authCompletions[0](true)
        await yieldMain()

        XCTAssertEqual(port.addedIDs, [])
        XCTAssertTrue(loadLedger(defaults).isEmpty)
    }

    func testAuthorizationDialogRescheduleUsesLatestExpiry() async throws {
        let fixture = try makeVault()
        let created = try insertSoonExpiringCredential(in: fixture.vault, name: "Auth Reschedule")
        let port = DeferredExpiryReminderNotificationPort()
        let defaults = makeDefaults()
        let controller = makeController(vault: fixture.vault, defaults: defaults, port: port)

        controller.reconcile()
        port.statusCompletions[0](.notDetermined)
        await yieldMain()
        XCTAssertEqual(port.authCompletions.count, 1)

        let later = now.addingTimeInterval(20 * 24 * 60 * 60)
        try fixture.vault.updateCredentialMetadata(
            id: created.id,
            name: "Auth Reschedule",
            usageInstructions: "",
            groupName: nil,
            permission: .ask,
            expiresAt: later,
            using: .allow
        )
        controller.reconcile()
        port.statusCompletions[1](.authorized)
        await yieldMain()

        port.authCompletions[0](true)
        await yieldMain()

        XCTAssertEqual(port.addedIDs, [created.id])
        XCTAssertEqual(port.addCalls.count, 1)
        XCTAssertNotNil(port.addCalls[0].request.trigger)
        port.addCompletions[0](nil)
        await yieldMain()
        XCTAssertEqual(loadLedger(defaults)[created.id]?.expiresAt, later)
        XCTAssertEqual(loadLedger(defaults)[created.id]?.delivered, false)
    }

    func testDelayedAddFailureKeepsPendingShowsErrorRetriesThenDeduplicates() async throws {
        let fixture = try makeVault()
        let created = try insertSoonExpiringCredential(in: fixture.vault, name: "Add Failure")
        let port = DeferredExpiryReminderNotificationPort()
        let defaults = makeDefaults()
        let controller = makeController(vault: fixture.vault, defaults: defaults, port: port)
        var failures: [String] = []
        controller.onAuthorizationFailure = { failures.append($0) }

        controller.reconcile()
        port.statusCompletions[0](.authorized)
        await yieldMain()
        XCTAssertEqual(port.addCompletions.count, 1)
        XCTAssertTrue(loadLedger(defaults).isEmpty)

        port.addCompletions[0](SyntheticNotificationAddFailure())
        await yieldMain()
        XCTAssertEqual(failures, [CredentialExpiryReminderCopy.deliveryFailedKey])
        XCTAssertTrue(loadLedger(defaults).isEmpty)
        XCTAssertEqual(
            AppLanguage.localized(CredentialExpiryReminderCopy.deliveryFailedKey, language: "zh-Hans"),
            "请旨无法投递到期提醒。将在下次启动或凭证变化后重试。"
        )

        controller.reconcile()
        port.statusCompletions[1](.authorized)
        await yieldMain()
        XCTAssertEqual(port.addCompletions.count, 2)
        port.addCompletions[1](nil)
        await yieldMain()
        XCTAssertEqual(loadLedger(defaults)[created.id]?.delivered, true)

        controller.reconcile()
        port.statusCompletions[2](.authorized)
        await yieldMain()
        XCTAssertEqual(port.addCompletions.count, 2)
    }

    func testInFlightAddAfterDeleteDoesNotResurrectLedger() async throws {
        let fixture = try makeVault()
        let created = try insertSoonExpiringCredential(in: fixture.vault, name: "In Flight Delete")
        let port = DeferredExpiryReminderNotificationPort()
        let defaults = makeDefaults()
        let controller = makeController(vault: fixture.vault, defaults: defaults, port: port)

        controller.reconcile()
        port.statusCompletions[0](.authorized)
        await yieldMain()
        XCTAssertEqual(port.addCompletions.count, 1)

        try fixture.vault.deleteTextCredential(id: created.id, using: .allow)
        controller.reconcile()
        port.statusCompletions[1](.authorized)
        await yieldMain()

        port.addCompletions[0](nil)
        await yieldMain()
        XCTAssertNil(loadLedger(defaults)[created.id])
        XCTAssertTrue(port.removed.contains(created.id))
    }

    func testInFlightAddAfterRescheduleDoesNotWriteOldExpiry() async throws {
        let fixture = try makeVault()
        let created = try insertSoonExpiringCredential(in: fixture.vault, name: "In Flight Reschedule")
        let oldExpiry = now.addingTimeInterval(2 * 24 * 60 * 60)
        let later = now.addingTimeInterval(20 * 24 * 60 * 60)
        let port = DeferredExpiryReminderNotificationPort()
        let defaults = makeDefaults()
        let controller = makeController(vault: fixture.vault, defaults: defaults, port: port)

        controller.reconcile()
        port.statusCompletions[0](.authorized)
        await yieldMain()
        XCTAssertEqual(port.addCompletions.count, 1)

        try fixture.vault.updateCredentialMetadata(
            id: created.id,
            name: "In Flight Reschedule",
            usageInstructions: "",
            groupName: nil,
            permission: .ask,
            expiresAt: later,
            using: .allow
        )
        controller.reconcile()
        port.statusCompletions[1](.authorized)
        await yieldMain()
        XCTAssertEqual(port.addCompletions.count, 2)

        port.addCompletions[0](nil)
        await yieldMain()
        XCTAssertNotEqual(loadLedger(defaults)[created.id]?.expiresAt, oldExpiry)

        port.addCompletions[1](nil)
        await yieldMain()
        XCTAssertEqual(loadLedger(defaults)[created.id]?.expiresAt, later)
        XCTAssertEqual(loadLedger(defaults)[created.id]?.delivered, false)
    }

    private func makeController(
        vault: Vault,
        defaults: UserDefaults,
        port: DeferredExpiryReminderNotificationPort
    ) -> CredentialExpiryReminderController {
        CredentialExpiryReminderController(
            vault: { vault },
            now: { self.now },
            defaults: defaults,
            ledgerKey: "ledger",
            notificationCenter: port.center
        )
    }

    private func insertSoonExpiringCredential(in vault: Vault, name: String) throws -> ManagedTextCredential {
        try vault.createTextCredential(
            .init(
                name: name,
                value: "SYNTHETIC",
                permission: .ask,
                expiresAt: now.addingTimeInterval(2 * 24 * 60 * 60)
            ),
            using: .allow
        )
    }

    private func makeVault() throws -> (vault: Vault, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyExpiryAsync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(
            store: try VaultStore(path: directory.appendingPathComponent("vault.db").path),
            key: SymmetricKey(data: Data(repeating: 0x41, count: 32)),
            now: { self.now }
        )
        try vault.beginManagementSession(using: .allow)
        return (vault, directory)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AskKey.expiry.async.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func loadLedger(_ defaults: UserDefaults) -> [String: ExpiryReminderLedgerEntry] {
        guard let data = defaults.data(forKey: "ledger") else { return [:] }
        return (try? JSONDecoder().decode([String: ExpiryReminderLedgerEntry].self, from: data)) ?? [:]
    }

    private func yieldMain() async {
        try? await Task.sleep(nanoseconds: 30_000_000)
    }
}

final class DeferredExpiryReminderNotificationPort: @unchecked Sendable {
    struct AddCall {
        let request: UNNotificationRequest
        let completion: (Error?) -> Void
    }

    var statusCompletions: [(UNAuthorizationStatus) -> Void] = []
    var authCompletions: [(Bool) -> Void] = []
    var addCalls: [AddCall] = []
    var addCompletions: [(Error?) -> Void] { addCalls.map(\.completion) }
    var addedIDs: [String] {
        addCalls.map { call in
            let prefix = "askkey-expiry-"
            let identifier = call.request.identifier
            return identifier.hasPrefix(prefix) ? String(identifier.dropFirst(prefix.count)) : identifier
        }
    }
    var removed: [String] = []

    var center: ExpiryReminderNotificationCenter {
        ExpiryReminderNotificationCenter(
            loadAuthorizationStatus: { [weak self] completion in
                self?.statusCompletions.append(completion)
            },
            requestAuthorization: { [weak self] completion in
                self?.authCompletions.append(completion)
            },
            add: { [weak self] request, completion in
                self?.addCalls.append(AddCall(request: request, completion: completion))
            },
            remove: { [weak self] id in
                self?.removed.append(id)
            }
        )
    }
}
