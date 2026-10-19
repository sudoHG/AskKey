import Darwin
import XCTest
@testable import AskKeyBroker

final class BrokerSocketOwnershipTests: BrokerProtocolTestCase {
    func testStartRefusesLiveListenerAndFailedInstanceCannotUnlinkIt() throws {
        let path = try makeSocketPath()
        let first = makeServer(path)
        try first.start()
        defer { first.stop() }
        let identity = try XCTUnwrap(BrokerSocketPathIdentity.read(path))
        let second = makeServer(path)
        XCTAssertThrowsError(try second.start())
        second.stop()
        XCTAssertEqual(try BrokerSocketPathIdentity.read(path), identity)
        let connection = try connectRaw(to: path)
        close(connection)
    }

    func testStartRecoversStaleSocket() throws {
        let path = try makeSocketPath()
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var address = try makeBrokerAddress(path: path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(descriptor)
        XCTAssertEqual(bound, 0)
        let server = makeServer(path)
        try server.start()
        defer { server.stop() }
        let connection = try connectRaw(to: path)
        close(connection)
    }

    func testStopLeavesOwnSocketForTheNextStartupToRecover() throws {
        let path = try makeSocketPath()
        let server = makeServer(path)
        try server.start()
        let identity = try XCTUnwrap(BrokerSocketPathIdentity.read(path))
        server.stop()
        XCTAssertEqual(try BrokerSocketPathIdentity.read(path), identity)
        let successor = makeServer(path)
        try successor.start()
        defer { successor.stop() }
        let connection = try connectRaw(to: path)
        close(connection)
    }

    func testStartupLockProtectsSocketBeforeItBeginsListening() throws {
        let path = try makeSocketPath()
        let startup = try BrokerSocketStartupLock.acquire(for: path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        var address = try makeBrokerAddress(path: path)
        XCTAssertEqual(withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }, 0)
        let identity = try XCTUnwrap(BrokerSocketPathIdentity.read(path))
        try withExtendedLifetime(startup) {
            let second = makeServer(path)
            XCTAssertThrowsError(try second.start())
            second.stop()
            XCTAssertEqual(try BrokerSocketPathIdentity.read(path), identity)
        }
    }

    func testStopPreservesReplacementSocketAndIsIdempotent() throws {
        let path = try makeSocketPath()
        let first = makeServer(path)
        try first.start()
        defer { first.stop() }
        XCTAssertEqual(unlink(path), 0)
        let replacement = makeServer(path)
        try replacement.start()
        defer { replacement.stop() }
        let identity = try XCTUnwrap(BrokerSocketPathIdentity.read(path))
        first.stop()
        first.stop()
        XCTAssertEqual(try BrokerSocketPathIdentity.read(path), identity)
        let connection = try connectRaw(to: path)
        close(connection)
    }

    func testStartAndStopPreserveNonSocketPath() throws {
        let path = try makeSocketPath()
        let value = Data("synthetic".utf8)
        try value.write(to: URL(fileURLWithPath: path))
        let server = makeServer(path)
        XCTAssertThrowsError(try server.start())
        server.stop()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), value)
    }

    private func makeServer(_ path: String) -> BrokerSocketServer {
        BrokerSocketServer(socketPath: path,
                           handler: BrokerRequestHandler(catalog: { _ in [] }, requestStatus: { _, _ in nil }))
    }
}
