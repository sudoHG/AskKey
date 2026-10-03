import XCTest
@testable import AskKeyBroker
import AskKeyBrokerC
import Darwin

final class BrokerProtocolFrameTests: BrokerProtocolTestCase {
    func testOversizedTruncatedAndSlowFramesFailClosed() throws {
        let socketPath = try makeSocketPath()
        let handler = BrokerRequestHandler(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        addTeardownBlock { server.stop() }

        let oversized = try connectRaw(to: socketPath)
        defer { close(oversized) }
        var tooLarge = UInt32(BrokerLimits.maximumFrameBytes + 1).bigEndian
        XCTAssertEqual(write(oversized, &tooLarge, 4), 4)
        XCTAssertEqual(try readResponse(from: oversized), .failure(.resourceExhausted))

        let truncated = try connectRaw(to: socketPath)
        defer { close(truncated) }
        var ten = UInt32(10).bigEndian
        XCTAssertEqual(write(truncated, &ten, 4), 4)
        XCTAssertEqual(write(truncated, "{}", 2), 2)
        XCTAssertEqual(shutdown(truncated, SHUT_WR), 0)
        XCTAssertEqual(try readResponse(from: truncated), .failure(.deadlineExceeded))

        let slow = try connectRaw(to: socketPath)
        defer { close(slow) }
        var oneHeaderByte: UInt8 = 0
        XCTAssertEqual(write(slow, &oneHeaderByte, 1), 1)
        XCTAssertEqual(try readResponse(from: slow), .failure(.deadlineExceeded))

        let drip = try connectRaw(to: socketPath)
        defer { close(drip) }
        var dripByte: UInt8 = 0
        XCTAssertEqual(write(drip, &dripByte, 1), 1)
        usleep(700_000)
        XCTAssertEqual(write(drip, &dripByte, 1), 1)
        usleep(700_000)
        XCTAssertEqual(write(drip, &dripByte, 1), 1)
        XCTAssertEqual(try readResponse(from: drip), .failure(.deadlineExceeded))
    }
    func testPartialPayloadEOFTimeoutAndReadErrorClearBytesAlreadyRead() throws {
        let socketPath = try makeSocketPath()
        let cleared = FailedReadBufferRecorder()
        let handler = BrokerRequestHandler(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: handler,
            failedReadBufferCleared: { cleared.record($0) }
        )
        try server.start()
        addTeardownBlock { server.stop() }
        let partial = Data("caller-known-partial-value".utf8)
        let declaredLength = partial.count + 16

        let eof = try connectRaw(to: socketPath)
        defer { close(eof) }
        try writePartialFrame(fd: eof, declaredLength: declaredLength, partial: partial)
        XCTAssertEqual(shutdown(eof, SHUT_WR), 0)
        XCTAssertEqual(try readResponse(from: eof), .failure(.deadlineExceeded))
        try assertClearedPartial(
            try cleared.next(),
            expectedBytesRead: partial.count,
            expectedFailure: .endOfFile
        )

        let timeout = try connectRaw(to: socketPath)
        defer { close(timeout) }
        try writePartialFrame(fd: timeout, declaredLength: declaredLength, partial: partial)
        XCTAssertEqual(try readResponse(from: timeout), .failure(.deadlineExceeded))
        try assertClearedPartial(
            try cleared.next(),
            expectedBytesRead: partial.count,
            expectedFailure: .deadline
        )

        BrokerSocketServer.exercisePartialReadErrorForTesting(
            partial: partial,
            declaredLength: declaredLength,
            errorCode: EIO,
            failedReadBufferCleared: { cleared.record($0) }
        )
        let readError = try cleared.next()
        try assertClearedPartial(
            readError,
            expectedBytesRead: partial.count,
            expectedFailure: .readError(EIO)
        )
    }
    func testOversizedFieldsAndResponsesFailClosed() throws {
        let oversizedField = String(repeating: "x", count: BrokerLimits.maximumFieldBytes + 1)
        let handler = BrokerRequestHandler(
            catalog: { _ in
                (0..<BrokerLimits.maximumResponseBytes).map {
                    .init(name: "credential-\($0)", payloadKind: .text, usageInstructions: "", environmentVariable: nil, expired: false)
                }
            },
            requestStatus: { _, _ in nil }
        )
        XCTAssertEqual(
            handler.handle(.init(version: 1, method: "request.status", requestID: oversizedField, capability: "c")),
            .failure(.invalidRequest)
        )

        let socketPath = try makeSocketPath()
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        addTeardownBlock { server.stop() }
        XCTAssertEqual(
            try BrokerSocketClient(socketPath: socketPath).send(.init(version: 1, method: "catalog")),
            .failure(.responseTooLarge)
        )
    }
}
