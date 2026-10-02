import XCTest
import CryptoKit
@testable import AskKeyCore

final class LocalVaultLifecycleTests: XCTestCase {
    func testEraseConfirmationMatchesTheFrozenChineseWorkspace() {
        XCTAssertEqual(LocalVaultEraseLanguage.simplifiedChinese.confirmationText, "抹除")
    }

    func testEnglishEraseConfirmationRunsTheRealCoordinator() throws {
        let harness = LifecycleHarness()

        try harness.coordinator.erase(
            confirmation: "ERASE",
            language: .english,
            using: .allow
        )

        XCTAssertEqual(
            harness.actions,
            [.quiesceOperations, .cleanupDeliveries, .stopBackups, .deleteData, .deleteKey]
        )
    }

    func testEraseRejectsTheOtherLanguagesConfirmationWord() {
        for (confirmation, language) in [
            ("抹除", LocalVaultEraseLanguage.english),
            ("ERASE", LocalVaultEraseLanguage.simplifiedChinese),
        ] {
            let harness = LifecycleHarness()
            XCTAssertThrowsError(
                try harness.coordinator.erase(
                    confirmation: confirmation,
                    language: language,
                    using: .allow
                )
            ) { error in
                XCTAssertEqual(error as? LocalVaultEraseError, .confirmationMismatch)
            }
            XCTAssertTrue(harness.actions.isEmpty)
        }
    }

    func testEraseRequiresDeviceAuthenticationAndExactConfirmation() throws {
        let harness = LifecycleHarness()

        XCTAssertThrowsError(
            try harness.coordinator.erase(
                confirmation: LocalVaultEraseLanguage.simplifiedChinese.confirmationText,
                language: .simplifiedChinese,
                using: .deny
            )
        ) { error in
            XCTAssertEqual(error as? LocalVaultEraseError, .authenticationRequired)
        }
        XCTAssertThrowsError(
            try harness.coordinator.erase(
                confirmation: "erase ask key",
                language: .simplifiedChinese,
                using: .allow
            )
        ) { error in
            XCTAssertEqual(error as? LocalVaultEraseError, .confirmationMismatch)
        }

        XCTAssertNil(try harness.journal.load())
        XCTAssertTrue(harness.actions.isEmpty)
    }

    func testEraseQuiescesEverythingAndDeletesLocalKeyLast() throws {
        let harness = LifecycleHarness()

        try harness.coordinator.erase(
            confirmation: LocalVaultEraseLanguage.simplifiedChinese.confirmationText,
            language: .simplifiedChinese,
            using: .allow
        )

        XCTAssertEqual(
            harness.actions,
            [.quiesceOperations, .cleanupDeliveries, .stopBackups, .deleteData, .deleteKey]
        )
        XCTAssertNil(try harness.journal.load())
    }

    func testEveryEraseCrashPointRecoversForwardWithoutDeletingKeyEarly() throws {
        for crashAction in LifecycleAction.allCases {
            let harness = LifecycleHarness(crashAfter: crashAction)

            XCTAssertThrowsError(
                try harness.coordinator.erase(
                    confirmation: LocalVaultEraseLanguage.simplifiedChinese.confirmationText,
                    language: .simplifiedChinese,
                    using: .allow
                )
            )
            XCTAssertNotNil(try harness.journal.load(), "missing journal after \(crashAction)")

            try harness.coordinator.recoverIfNeeded()

            XCTAssertNil(try harness.journal.load(), "journal survived recovery after \(crashAction)")
            let dataIndex = try XCTUnwrap(harness.actions.lastIndex(of: .deleteData))
            let keyIndex = try XCTUnwrap(harness.actions.lastIndex(of: .deleteKey))
            XCTAssertLessThan(dataIndex, keyIndex, "key was deleted before data after \(crashAction)")
            XCTAssertEqual(harness.actions.last, .deleteKey)
        }
    }

    func testExistingJournalRecoversWithoutRepeatingAuthenticationOrConfirmation() throws {
        let harness = LifecycleHarness()
        try harness.journal.save(.deliveriesCleared)

        try harness.coordinator.recoverIfNeeded()

        XCTAssertEqual(harness.actions, [.stopBackups, .deleteData, .deleteKey])
        XCTAssertNil(try harness.journal.load())
    }

    func testVaultQuiescingCancelsRequestsAndCleansDeliveriesBeforeBackupAndKeySteps() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyLocalEraseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let deliveryManager = try FileDeliveryManager(
            rootURL: root.appendingPathComponent("deliveries", isDirectory: true)
        )
        let vault = Vault(
            store: try VaultStore(path: root.appendingPathComponent("vault.db").path),
            key: SymmetricKey(size: .bits256),
            fileDeliveryManager: deliveryManager
        )
        try vault.brokerRequests.register(requestID: "pending", capability: "capability")
        let delivery = try deliveryManager.materialize(
            credentialID: "credential",
            bytes: Data("temporary-secret".utf8)
        )
        let destructiveSteps = LifecycleActionRecorder()
        let coordinator = vault.makeLocalEraseCoordinator(
            journal: MemoryLocalVaultEraseJournalStore(),
            stopBackups: {
                XCTAssertTrue(try vault.isAgentAccessPaused())
                XCTAssertEqual(
                    vault.brokerRequests.status(requestID: "pending", capability: "capability"),
                    .cancelled
                )
                XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.url.path))
                destructiveSteps.append(.stopBackups)
            },
            deleteEncryptedData: { destructiveSteps.append(.deleteData) },
            deleteLocalKey: { destructiveSteps.append(.deleteKey) }
        )

        try coordinator.erase(
            confirmation: LocalVaultEraseLanguage.simplifiedChinese.confirmationText,
            language: .simplifiedChinese,
            using: .allow
        )

        XCTAssertEqual(destructiveSteps.values, [.stopBackups, .deleteData, .deleteKey])
    }
}

private enum LifecycleAction: String, CaseIterable {
    case quiesceOperations
    case cleanupDeliveries
    case stopBackups
    case deleteData
    case deleteKey
}

private final class LifecycleHarness {
    let journal = MemoryLocalVaultEraseJournalStore()
    private(set) var actions: [LifecycleAction] = []
    private var crashAfter: LifecycleAction?
    lazy var coordinator = LocalVaultEraseCoordinator(
        journal: journal,
        actions: .init(
            quiesceOperations: { try self.perform(.quiesceOperations) },
            cleanupDeliveries: { try self.perform(.cleanupDeliveries) },
            stopBackups: { try self.perform(.stopBackups) },
            deleteEncryptedData: { try self.perform(.deleteData) },
            deleteLocalKey: { try self.perform(.deleteKey) }
        )
    )

    init(crashAfter: LifecycleAction? = nil) {
        self.crashAfter = crashAfter
    }

    private func perform(_ action: LifecycleAction) throws {
        actions.append(action)
        if crashAfter == action {
            crashAfter = nil
            throw LifecycleTestError.injected
        }
    }
}

private final class MemoryLocalVaultEraseJournalStore: LocalVaultEraseJournalStore {
    private var state: LocalVaultEraseState?

    func load() throws -> LocalVaultEraseState? { state }
    func save(_ state: LocalVaultEraseState) throws { self.state = state }
    func clear() throws { state = nil }
}

private enum LifecycleTestError: Error {
    case injected
}

private final class LifecycleActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LifecycleAction] = []

    var values: [LifecycleAction] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ action: LifecycleAction) {
        lock.lock(); storage.append(action); lock.unlock()
    }
}
