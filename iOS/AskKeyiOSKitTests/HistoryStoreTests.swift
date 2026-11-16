import AskKeyDevices
import Security
import XCTest
@testable import AskKeyiOSKit

/// The history's storage (#349, ADR 0014 → iPhone app → History, Stored and
/// Kept): what the file holds, its encryption, binding, protection and key,
/// and the 30-day and 500-entry limits.
@MainActor
final class HistoryStoreTests: XCTestCase {
    private static let day: TimeInterval = 86_400

    // MARK: What is kept

    func testTheFileHoldsTheNamesButNeverTheCommandFolderDeliveredNamesOrPurpose() async throws {
        let world = TestWorld()
        await world.setUpPhone()
        try await world.pair()
        let display = ApprovalRequestDisplay(
            requesterName: "Requester-7f3a", purpose: "PURPOSE-c41d-do-not-keep", credentialName: "Credential-2b9e",
            commandLine: "COMMAND-e85f --flag ARGUMENT-0a6c", workingDirectory: "/FOLDER-9d27/project",
            executableName: "Program-5c1b",
            deliveryRows: [ApprovalDeliveryRow(kind: .environmentVariable, label: "LABEL-77e0", variable: "VARIABLE_31F4"),
                           ApprovalDeliveryRow(kind: .temporaryFile, label: "", variable: "FILEVAR_86AA")])
        let sealed = try await world.sendRequest(display: display)
        await world.model.processInbox()
        try await world.sendClosed(.decidedOnMac, for: sealed)
        await world.model.processInbox()

        let bytes = try XCTUnwrap(world.historyFiles.storedData)
        let plaintext = try XCTUnwrap(world.storedHistoryPlaintext)
        let text = String(decoding: plaintext, as: UTF8.self)
        for kept in ["Requester-7f3a", "Credential-2b9e", "Program-5c1b"] {
            XCTAssertTrue(text.contains(kept), "the entry keeps \(kept)")
            XCTAssertNil(bytes.range(of: Data(kept.utf8)), "but only encrypted")
        }
        for secret in ["COMMAND-e85f", "ARGUMENT-0a6c", "FOLDER-9d27", "VARIABLE_31F4", "FILEVAR_86AA", "LABEL-77e0",
                       "PURPOSE-c41d"] {
            XCTAssertNil(bytes.range(of: Data(secret.utf8)), "never in the file: \(secret)")
            XCTAssertFalse(text.contains(secret), "never in the entry: \(secret)")
        }
        XCTAssertNil(bytes.range(of: sealed.sealed.envelope.body), "never the envelope")
        XCTAssertFalse(text.contains(sealed.sealed.envelope.body.base64EncodedString()), "never the envelope")
        let memory = String(decoding: try JSONEncoder().encode(world.model.historyState), as: UTF8.self)
        for secret in ["COMMAND-e85f", "FOLDER-9d27", "VARIABLE_31F4", "LABEL-77e0", "PURPOSE-c41d"] {
            XCTAssertFalse(memory.contains(secret), "never in memory either: \(secret)")
        }
    }

    // MARK: Encryption and binding

    func testAFileBoundToAnotherAccountIsDeletedUnread() async throws {
        let world = TestWorld()
        await world.setUpPhone()
        try world.storeHistory([TestWorld.historyEntry(endedAt: world.clock.now())], account: "_user-z")
        let relaunched = await world.relaunch()
        XCTAssertTrue(relaunched.history.isEmpty)
        XCTAssertNil(world.historyFiles.storedData)
        XCTAssertNil(world.historyKeys.storedKey, "the key that could not open it goes too")
    }

    func testAFileWithoutItsKeyOrDamagedIsDeletedUnread() async throws {
        let world = TestWorld()
        await world.setUpPhone()
        try world.storeHistory([TestWorld.historyEntry(endedAt: world.clock.now())])
        world.historyKeys.storedKey = nil
        var relaunched = await world.relaunch()
        XCTAssertTrue(relaunched.history.isEmpty)
        XCTAssertNil(world.historyFiles.storedData)

        try world.storeHistory([TestWorld.historyEntry(endedAt: world.clock.now())])
        var data = try XCTUnwrap(world.historyFiles.storedData)
        data[data.count - 1] ^= 0xFF
        world.historyFiles.storedData = data
        relaunched = await world.relaunch()
        XCTAssertTrue(relaunched.history.isEmpty)
        XCTAssertNil(world.historyFiles.storedData)
    }

    func testAFileThatCannotBeReadNowIsKept() async throws {
        let world = TestWorld()
        await world.setUpPhone()
        let entry = TestWorld.historyEntry(endedAt: world.clock.now())
        try world.storeHistory([entry])
        world.historyFiles.readsFail = true
        let relaunched = await world.relaunch()
        XCTAssertTrue(relaunched.history.isEmpty)
        XCTAssertNotNil(world.historyFiles.storedData)
        world.historyFiles.readsFail = false
        await relaunched.becameActive()
        XCTAssertEqual(relaunched.history, [entry])
    }

    func testTheKeyIsThisDeviceOnlyInTheAppsOwnAccessGroup() throws {
        let group = "ABCDE12345.com.sudohg.askkey.ios"
        let store = KeychainHistoryKeyStore(service: "com.sudohg.askkey.ios.history.tests", accessGroup: group)
        let query = try XCTUnwrap(store.query())
        XCTAssertEqual(query[kSecClass] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService] as? String, "com.sudohg.askkey.ios.history.tests")
        XCTAssertEqual(query[kSecAttrAccessGroup] as? String, group)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, true)
        XCTAssertEqual(query[kSecAttrSynchronizable] as? Bool, false)
        let addition = try XCTUnwrap(store.addition(Data(repeating: 7, count: 32)))
        XCTAssertEqual(addition[kSecAttrAccessible] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(addition[kSecAttrAccessGroup] as? String, group)
        XCTAssertEqual(KeychainHistoryKeyStore.service, "com.sudohg.askkey.ios.history")
        XCTAssertNotEqual(KeychainHistoryKeyStore.service, DataProtectionKeychain.service,
                          "not the service the notification extension reads")

        // Without the app's own group nothing is stored, never in the shared default group.
        let unconfigured = KeychainHistoryKeyStore(service: "com.sudohg.askkey.ios.history.tests", accessGroup: nil)
        XCTAssertNil(unconfigured.query())
        XCTAssertThrowsError(try unconfigured.loadKey())
        XCTAssertThrowsError(try unconfigured.saveKey(Data(repeating: 7, count: 32)))
        XCTAssertNoThrow(try unconfigured.deleteKey())
    }

    func testTheFileHasTheRequestStoresProtectionAndItsDirectoryIsExcludedFromBackups() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let history = FileHistoryStore(base: base)
        try history.saveHistory(Data([1, 2, 3]))
        let approvals = FileApprovalStateStore(directory: base)
        try approvals.saveApprovals(Data("{}".utf8))

        XCTAssertTrue(FileHistoryStore.writeOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
        let historyFile = history.directory.appendingPathComponent("history")
        let approvalsFile = base.appendingPathComponent("Approvals/approvals.json")
        let protection = try FileManager.default.attributesOfItem(atPath: historyFile.path)[.protectionKey] as? FileProtectionType
        let requestProtection = try FileManager.default.attributesOfItem(atPath: approvalsFile.path)[.protectionKey]
            as? FileProtectionType
        XCTAssertEqual(protection, requestProtection)
        XCTAssertEqual(history.directory.lastPathComponent, "History")
        XCTAssertEqual(try history.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try approvalsFile.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup, false, "the request store is not excluded")
        XCTAssertEqual(try history.loadHistory(), Data([1, 2, 3]))

        try history.setDeletionPending(true)
        XCTAssertTrue(history.isDeletionPending)
        try history.removeHistory()
        try history.setDeletionPending(false)
        XCTAssertFalse(history.isDeletionPending)
        XCTAssertNil(try history.loadHistory())
        XCTAssertNoThrow(try history.removeHistory(), "deleting a missing file succeeds")
    }

    // MARK: Retention

    func testPruningDropsEntriesThirtyDaysOldThenTheOldestBeyondFiveHundred() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var open = TestWorld.historyEntry(endedAt: now)
        open.endedAt = nil
        open.receivedAt = now.addingTimeInterval(-40 * Self.day)
        var history = StoredHistory(entries: [
            TestWorld.historyEntry(endedAt: now.addingTimeInterval(-30 * Self.day)),
            TestWorld.historyEntry(endedAt: now.addingTimeInterval(-30 * Self.day + 1)),
            open,
        ])
        history.prune(now: now)
        XCTAssertEqual(history.entries.count, 2, "30 days by ended time; an open entry stays")

        let many = (0..<502).map { TestWorld.historyEntry(endedAt: now.addingTimeInterval(TimeInterval(-$0 * 60))) }
        history = StoredHistory(entries: many + [open])
        history.prune(now: now)
        XCTAssertEqual(history.entries.filter(\.isCompleted).count, 500)
        XCTAssertEqual(history.entries.compactMap(\.endedAt).min(), now.addingTimeInterval(-499 * 60), "the oldest go first")
        XCTAssertTrue(history.entries.contains(open))
    }

    func testEntriesArePrunedAtLaunchOnWriteAndWhenTheAppComesToTheFront() async throws {
        let world = TestWorld()
        await world.setUpPhone()
        try await world.pair()
        let now = world.clock.now()
        let old = TestWorld.historyEntry(endedAt: now.addingTimeInterval(-31 * Self.day))
        let aging = TestWorld.historyEntry(endedAt: now.addingTimeInterval(-30 * Self.day + 3_600))
        let recent = (0..<499).map { TestWorld.historyEntry(endedAt: now.addingTimeInterval(TimeInterval(-$0 * 60))) }
        try world.storeHistory([old, aging] + recent)

        let relaunched = await world.relaunch()
        XCTAssertEqual(relaunched.history.count, 500, "at launch: older than 30 days")
        XCTAssertFalse(relaunched.history.contains(old))
        XCTAssertEqual(world.storedHistory?.entries.count, 500, "and written")

        let sealed = try await world.sendRequest()
        await relaunched.processInbox()
        try await world.sendClosed(.expired, for: sealed)
        await relaunched.processInbox()
        XCTAssertEqual(relaunched.history.count, 500, "on write: at most 500")
        XCTAssertFalse(relaunched.history.contains(aging), "the oldest goes first")
        XCTAssertEqual(world.storedHistory?.entries.count, 500)

        world.clock.advance(by: 30 * Self.day - 120)
        await relaunched.becameActive()
        XCTAssertEqual(relaunched.history.count, 3, "coming to the front: History never shows an entry older than 30 days")
        XCTAssertEqual(world.storedHistory?.entries.count, 3)
    }

    func testAnUnreadableFileWhoseDeletionFailsBlocksWritesUntilItIsDeleted() async throws {
        let world = TestWorld()
        await world.setUpPhone()
        try await world.pair()
        try world.storeHistory([TestWorld.historyEntry(endedAt: world.clock.now())], account: "_user-z")
        let foreign = world.historyFiles.storedData
        world.historyFiles.removalsFail = true
        let relaunched = await world.relaunch()
        XCTAssertNil(world.historyKeys.storedKey, "the key goes first")
        XCTAssertTrue(world.historyFiles.isDeletionPending)
        let sealed = try await world.sendRequest()
        await relaunched.processInbox()
        XCTAssertEqual(world.historyFiles.storedData, foreign, "nothing is written over it")

        world.historyFiles.removalsFail = false
        await relaunched.becameActive()
        XCTAssertFalse(world.historyFiles.isDeletionPending)
        XCTAssertEqual(world.storedHistory?.entries.map(\.recordName), [sealed.sealed.messageID.text])
    }

    func testAPendingDeletionIsRetriedAtLaunchWithoutAnIdentity() async throws {
        let world = TestWorld()
        world.localState.inboxPosition = InboxPosition(userRecordName: "_user-a", token: nil)
        try world.storeHistory([TestWorld.historyEntry(endedAt: world.clock.now())])
        try world.historyFiles.setDeletionPending(true)
        await world.model.start()
        XCTAssertEqual(world.model.stage, .welcome)
        XCTAssertNil(world.historyFiles.storedData)
        XCTAssertNil(world.historyKeys.storedKey)
        XCTAssertFalse(world.historyFiles.isDeletionPending)
    }

    func testTheWelcomeSetupDeletesALeftoverHistoryBeforeItCreatesAnIdentity() async throws {
        let world = TestWorld()
        world.localState.inboxPosition = InboxPosition(userRecordName: "_user-a", token: nil)
        try world.storeHistory([TestWorld.historyEntry(endedAt: world.clock.now())])
        await world.setUpPhone()
        XCTAssertNil(world.historyFiles.storedData)
        XCTAssertNil(world.historyKeys.storedKey)
        XCTAssertTrue(world.model.history.isEmpty)
    }
}
