import Foundation
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class BrokerCatalogCancellationTests: XCTestCase {
    func testDelayedCancellationCannotReleaseItsDatabaseCallbackToSuccessorReadsOrWrites() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        let originalSQL = DispatchSemaphore(value: 0)
        let releaseSQL = DispatchSemaphore(value: 0)
        let originalSQLFinished = DispatchSemaphore(value: 0)
        let interruptEntered = DispatchSemaphore(value: 0)
        let releaseInterrupt = DispatchSemaphore(value: 0)
        let originalCallbackExited = DispatchSemaphore(value: 0)
        let successorEntered = DispatchSemaphore(value: 0)
        let successorFinished = DispatchSemaphore(value: 0)
        let writeEntered = DispatchSemaphore(value: 0)
        let writeFinished = DispatchSemaphore(value: 0)
        let cancellationFinished = DispatchSemaphore(value: 0)
        let writeResult = CatalogCancellationResult<Void>()
        defer { releaseSQL.signal(); releaseInterrupt.signal() }

        try store.db.write { db in
            var catalogStatements = 0
            db.trace(options: [.statement, .profile]) { event in
                switch event {
                case .statement(let statement) where statement.sql.hasPrefix("SELECT * FROM \"credentials\""):
                    catalogStatements += 1
                    if catalogStatements == 1 {
                        originalSQL.signal()
                        XCTAssertEqual(releaseSQL.wait(timeout: .now() + 5), .success)
                    }
                case .profile(let statement, _) where statement.sql.hasPrefix("SELECT * FROM \"credentials\""):
                    if catalogStatements == 1 { originalSQLFinished.signal() }
                default: break
                }
            }
        }

        let cancellation = BrokerCancellation()
        let original = try makeRead(store: store, cancellation: cancellation) {
            interruptEntered.signal()
            XCTAssertEqual(releaseInterrupt.wait(timeout: .now() + 5), .success)
            store.db.interrupt()
        }
        store.db.asyncRead {
            original.execute($0)
            originalCallbackExited.signal()
        }
        try awaitSignal(originalSQL)

        let successor = try makeRead(store: store, cancellation: BrokerCancellation()) { store.db.interrupt() }
        store.db.asyncRead {
            successorEntered.signal()
            successor.execute($0)
            successorFinished.signal()
        }
        store.db.asyncWrite({ db in
            writeEntered.signal()
            try db.execute(sql: "INSERT INTO config (key, value) VALUES (?, ?)", arguments: ["cancellation-successor", "committed"])
        }, completion: { _, result in
            writeResult.store(result)
            writeFinished.signal()
        })

        DispatchQueue.global().async {
            cancellation.cancel()
            cancellationFinished.signal()
        }
        try awaitSignal(interruptEntered)
        releaseSQL.signal()
        try awaitSignal(originalSQLFinished)

        // This is a bounded forbidden-event check, not a queue fence: the test
        // releases interrupt independently even when the correct lock blocks exit.
        XCTAssertEqual(originalCallbackExited.wait(timeout: .now() + 0.25), .timedOut)
        XCTAssertEqual(successorEntered.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(writeEntered.wait(timeout: .now()), .timedOut)
        releaseInterrupt.signal()

        try awaitSignal(cancellationFinished)
        let originalResult = try awaitReadResult(original)
        XCTAssertThrowsError(try originalResult.get()) { XCTAssertTrue($0 is BrokerCancellationError) }
        try awaitSignal(successorFinished)
        let successorResult = try awaitReadResult(successor)
        XCTAssertEqual(try successorResult.get().map(\.id), [fixture.credentialID])
        try awaitSignal(writeFinished)
        try XCTUnwrap(writeResult.value).get()
        XCTAssertEqual(try store.configValue(key: "cancellation-successor"), "committed")
        XCTAssertEqual(try store.fetchAllCredentials(cancellation: BrokerCancellation()).map(\.id), [fixture.credentialID])
        try store.db.read { _ in }
        XCTAssertEqual(store.pendingBrokerCatalogReadCount, 0)
    }

    func testActiveReadCancellationReturnsBeforeSQLiteCallbackDrains() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        let sqlEntered = DispatchSemaphore(value: 0)
        let releaseSQL = DispatchSemaphore(value: 0)
        let callbackExited = DispatchSemaphore(value: 0)
        let waiterFinished = DispatchSemaphore(value: 0)
        let cancellationFinished = DispatchSemaphore(value: 0)
        let waitResult = CatalogCancellationResult<[CredentialRecord]>()
        let interrupts = CatalogCancellationCounter()
        defer { releaseSQL.signal() }
        try store.db.write { db in
            var paused = false
            db.trace { event in
                guard case .statement(let statement) = event,
                      statement.sql.hasPrefix("SELECT * FROM \"credentials\""), !paused else { return }
                paused = true
                sqlEntered.signal()
                XCTAssertEqual(releaseSQL.wait(timeout: .now() + 5), .success)
            }
        }
        let cancellation = BrokerCancellation()
        let operation = try makeRead(store: store, cancellation: cancellation) {
            interrupts.increment()
            store.db.interrupt()
        }
        store.db.asyncRead {
            operation.execute($0)
            callbackExited.signal()
        }
        DispatchQueue.global().async {
            waitResult.store(Result { try operation.wait() })
            waiterFinished.signal()
        }
        try awaitSignal(sqlEntered)
        DispatchQueue.global().async {
            cancellation.cancel()
            cancellation.cancel()
            operation.cancel()
            cancellationFinished.signal()
        }

        try awaitSignal(waiterFinished)
        try awaitSignal(cancellationFinished)
        XCTAssertThrowsError(try XCTUnwrap(waitResult.value).get()) { XCTAssertTrue($0 is BrokerCancellationError) }
        XCTAssertEqual(interrupts.value, 1)
        XCTAssertEqual(callbackExited.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(store.pendingBrokerCatalogReadCount, 1)

        releaseSQL.signal()
        try awaitSignal(callbackExited)
        XCTAssertEqual(store.pendingBrokerCatalogReadCount, 0)
        XCTAssertEqual(try store.fetchAllCredentials(cancellation: BrokerCancellation()).map(\.id), [fixture.credentialID])
    }

    func testCancellationBeforeAdmissionDoesNotEnqueueDatabaseWork() throws {
        let fixture = try makeFixture()
        let statements = CatalogCancellationCounter()
        try fixture.store.db.write { db in
            db.trace { event in
                guard case .statement(let statement) = event,
                      statement.sql.hasPrefix("SELECT * FROM \"credentials\"") else { return }
                statements.increment()
            }
        }
        let cancellation = BrokerCancellation()
        cancellation.cancel()
        cancellation.cancel()
        XCTAssertThrowsError(try fixture.store.fetchAllCredentials(cancellation: cancellation)) {
            XCTAssertTrue($0 is BrokerCancellationError)
        }
        XCTAssertEqual(statements.value, 0)
        XCTAssertEqual(fixture.store.pendingBrokerCatalogReadCount, 0)
        XCTAssertEqual(try fixture.store.fetchAllCredentials(cancellation: BrokerCancellation()).map(\.id), [fixture.credentialID])
        XCTAssertEqual(statements.value, 1)
    }

    func testQueuedCancellationsRemainBoundedUntilDrainedAndCancelAdmissionWaiters() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        let databaseEntered = DispatchSemaphore(value: 0)
        let releaseDatabase = DispatchSemaphore(value: 0)
        let callbacks = DispatchGroup()
        let interrupts = CatalogCancellationCounter()
        defer { releaseDatabase.signal() }
        store.db.asyncWriteWithoutTransaction { _ in
            databaseEntered.signal()
            XCTAssertEqual(releaseDatabase.wait(timeout: .now() + 5), .success)
        }
        try awaitSignal(databaseEntered)
        for _ in 0..<BrokerLimits.maximumConcurrentRequests {
            let cancellation = BrokerCancellation()
            let operation = try makeRead(store: store, cancellation: cancellation) {
                interrupts.increment()
                store.db.interrupt()
            }
            callbacks.enter()
            store.db.asyncRead {
                operation.execute($0)
                callbacks.leave()
            }
            cancellation.cancel()
            cancellation.cancel()
            operation.cancel()
            let result = try awaitReadResult(operation)
            XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is BrokerCancellationError) }
        }
        XCTAssertEqual(store.pendingBrokerCatalogReadCount, BrokerLimits.maximumConcurrentRequests)
        XCTAssertEqual(interrupts.value, 0)

        let waitingCancellation = BrokerCancellation()
        let waiterStarted = DispatchSemaphore(value: 0)
        let waiterFinished = DispatchSemaphore(value: 0)
        let waitingResult = CatalogCancellationResult<[CredentialRecord]>()
        DispatchQueue.global().async {
            waiterStarted.signal()
            waitingResult.store(Result { try store.fetchAllCredentials(cancellation: waitingCancellation) })
            waiterFinished.signal()
        }
        try awaitSignal(waiterStarted)
        XCTAssertEqual(waiterFinished.wait(timeout: .now() + 0.25), .timedOut)
        waitingCancellation.cancel()
        try awaitSignal(waiterFinished)
        XCTAssertThrowsError(try XCTUnwrap(waitingResult.value).get()) { XCTAssertTrue($0 is BrokerCancellationError) }
        XCTAssertEqual(store.pendingBrokerCatalogReadCount, BrokerLimits.maximumConcurrentRequests)

        releaseDatabase.signal()
        XCTAssertEqual(callbacks.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(store.pendingBrokerCatalogReadCount, 0)
        XCTAssertEqual(interrupts.value, 0)
        XCTAssertEqual(try store.fetchAllCredentials(cancellation: BrokerCancellation()).map(\.id), [fixture.credentialID])
        try store.setConfigValue(key: "after-queued-cancellations", value: "committed")
        XCTAssertEqual(try store.configValue(key: "after-queued-cancellations"), "committed")
        XCTAssertEqual(store.pendingBrokerCatalogReadCount, 0)
    }

    func testCompletedReadIgnoresLateRepeatedCancellationDuringSuccessorWrite() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        let callbackExited = DispatchSemaphore(value: 0)
        let interrupts = CatalogCancellationCounter()
        let cancellation = BrokerCancellation()
        let operation = try makeRead(store: store, cancellation: cancellation) {
            interrupts.increment()
            store.db.interrupt()
        }
        store.db.asyncRead {
            operation.execute($0)
            callbackExited.signal()
        }
        try awaitSignal(callbackExited)
        let result = try awaitReadResult(operation)
        XCTAssertEqual(try result.get().map(\.id), [fixture.credentialID])
        XCTAssertEqual(store.pendingBrokerCatalogReadCount, 0)

        let writeEntered = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let writeFinished = DispatchSemaphore(value: 0)
        let writeResult = CatalogCancellationResult<Void>()
        defer { releaseWrite.signal() }
        try store.db.write { db in
            db.trace { event in
                guard case .statement(let statement) = event,
                      statement.sql.hasPrefix("INSERT INTO config") else { return }
                writeEntered.signal()
                XCTAssertEqual(releaseWrite.wait(timeout: .now() + 5), .success)
            }
        }
        store.db.asyncWrite({ db in
            try db.execute(sql: "INSERT INTO config (key, value) VALUES (?, ?)", arguments: ["after-completed-read", "committed"])
        }, completion: { _, result in
            writeResult.store(result)
            writeFinished.signal()
        })
        try awaitSignal(writeEntered)
        cancellation.cancel()
        cancellation.cancel()
        operation.cancel()
        XCTAssertEqual(interrupts.value, 0)
        releaseWrite.signal()
        try awaitSignal(writeFinished)
        try XCTUnwrap(writeResult.value).get()
        XCTAssertEqual(try store.configValue(key: "after-completed-read"), "committed")
        XCTAssertEqual(try store.fetchAllCredentials(cancellation: BrokerCancellation()).map(\.id), [fixture.credentialID])
        try store.db.read { _ in }
        XCTAssertEqual(store.pendingBrokerCatalogReadCount, 0)
    }

    private func makeRead(
        store: VaultStore, cancellation: BrokerCancellation,
        interrupt: @escaping @Sendable () -> Void
    ) throws -> CancellableCredentialRead {
        let operation = CancellableCredentialRead(
            admission: try store.brokerCatalogReadGate.acquire(cancellation: cancellation),
            interrupt: interrupt, authenticate: { try store.authenticatedCredential($0) }
        )
        cancellation.onCancel { [weak operation] in operation?.cancel() }
        return operation
    }

    private func awaitReadResult(
        _ operation: CancellableCredentialRead, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Result<[CredentialRecord], Error> {
        let result = CatalogCancellationResult<[CredentialRecord]>()
        let waiterFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result.store(Result { try operation.wait() })
            waiterFinished.signal()
        }
        try awaitSignal(waiterFinished, file: file, line: line)
        return try XCTUnwrap(result.value, file: file, line: line)
    }

    private func awaitSignal(_ signal: DispatchSemaphore, file: StaticString = #filePath, line: UInt = #line) throws {
        let result = signal.wait(timeout: .now() + 2)
        XCTAssertEqual(result, .success, file: file, line: line)
        if result != .success { throw CatalogCancellationTestError.timedOut }
    }

    private func makeFixture() throws -> (store: VaultStore, credentialID: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(path: directory.appendingPathComponent("vault.db").path)
        addTeardownBlock { try? store.close() }
        let vault = Vault(store: store, key: VaultCrypto.generateKey())
        try vault.beginManagementSession(using: .allow)
        let credential = try vault.createTextCredential(.init(name: "SYNTHETIC", value: "SYNTHETIC_VALUE"), using: .allow)
        return (store, credential.id)
    }
}

private final class CatalogCancellationResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    var value: Result<Value, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    func store(_ value: Result<Value, Error>) { lock.lock(); result = value; lock.unlock() }
}

private final class CatalogCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private enum CatalogCancellationTestError: Error { case timedOut }
