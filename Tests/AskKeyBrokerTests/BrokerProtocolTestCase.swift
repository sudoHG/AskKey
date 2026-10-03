import XCTest
@testable import AskKeyBroker
import AskKeyBrokerC
#if canImport(Darwin)
import Darwin
#endif

class BrokerProtocolTestCase: XCTestCase {
    func makeSocketPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("broker.sock").path
    }
    func connectRaw(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerSocketError.systemError("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); throw BrokerSocketError.pathTooLong }
        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
            path.withCString { strncpy(destination, $0, capacity - 1) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); throw BrokerSocketError.notRunning }
        return fd
    }
    func readResponse(from fd: Int32) throws -> BrokerResponse {
        let header = try readExactly(4, from: fd)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let body = try readExactly(Int(length), from: fd)
        return try JSONDecoder().decode(BrokerResponse.self, from: body)
    }
    func writePartialFrame(fd: Int32, declaredLength: Int, partial: Data) throws {
        var length = UInt32(declaredLength).bigEndian
        XCTAssertEqual(write(fd, &length, 4), 4)
        XCTAssertEqual(partial.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, partial.count)
    }
    func assertClearedPartial(
        _ cleared: BrokerClearedReadBuffer,
        expectedBytesRead: Int,
        expectedFailure: BrokerClearedReadFailure? = nil
    ) throws {
        XCTAssertEqual(cleared.bytesRead, expectedBytesRead)
        XCTAssertGreaterThan(cleared.bytesRead, 0)
        XCTAssertTrue(cleared.buffer.allSatisfy { $0 == 0 })
        if let expectedFailure { XCTAssertEqual(cleared.failure, expectedFailure) }
    }
    func readExactly(_ count: Int, from fd: Int32) throws -> Data {
        var result = Data()
        while result.count < count {
            var buffer = [UInt8](repeating: 0, count: count - result.count)
            let amount = read(fd, &buffer, buffer.count)
            guard amount > 0 else { throw BrokerSocketError.noResponse }
            result.append(contentsOf: buffer.prefix(amount))
        }
        return result
    }
}
