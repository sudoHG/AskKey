import XCTest
@testable import AskKeyBroker
import AskKeyBrokerC
import Darwin

final class BrokerProtocolRuntimeTests: BrokerProtocolTestCase {
    func testRuntimeNoResponseIsOutcomeUnknownWithoutRetry() throws {
        let socketPath = try makeSocketPath()
        let accepted = expectation(description: "request accepted")
        try startClosingServer(socketPath: socketPath, accepted: accepted)
        let nullInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        let nullOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))

        XCTAssertEqual(
            try BrokerSocketClient(socketPath: socketPath).run(
                .init(command: ["/usr/bin/true"], credentialNames: ["TOKEN"]),
                standardInputFD: nullInput.fileDescriptor,
                standardOutputFD: nullOutput.fileDescriptor,
                standardErrorFD: nullOutput.fileDescriptor
            ),
            .outcomeUnknown
        )
        wait(for: [accepted], timeout: 2)
    }
    func testSocketDisconnectCancelsRuntimeEvenWhenControlPipeRemainsOpen() throws {
        try assertRuntimeCancellation(.eof)
    }
    func testSocketResetCancelsRuntime() throws {
        try assertRuntimeCancellation(.reset)
    }
    func testProtocolDataDuringRuntimeCancelsWithoutBusyWaiting() throws {
        try assertRuntimeCancellation(.protocolData)
    }
    private enum RuntimeDisconnect { case eof, reset, protocolData }
    func testRuntimePassesCallerDescriptorsToBrokerSpawnWithoutReturningTargetOutput() throws {
        let socketPath = try makeSocketPath()
        let runtime = BrokerTextRuntime(resolveCredentials: { _, _ in
            .resolved([.init(environmentVariable: "TOKEN", value: "fd-secret")])
        })
        let handler = BrokerRequestHandler(
            catalog: { _ in [] },
            requestStatus: { _, _ in nil },
            textRun: { request, descriptors, cancellation in
                try runtime.run(
                    request,
                    standardInputFD: descriptors.standardInput,
                    standardOutputFD: descriptors.standardOutput,
                    standardErrorFD: descriptors.standardError,
                    controlFD: descriptors.control,
                    cancellation: cancellation
                )
            }
        )
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        addTeardownBlock { server.stop() }
        let output = Pipe()
        let nullInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        let nullError = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))

        let result = try BrokerSocketClient(socketPath: socketPath).run(
            .init(
                operationID: "fd-runtime",
                command: ["/bin/sh", "-c", "printf '%s' \"$TOKEN\"; exit 17"],
                credentialNames: ["TOKEN"]
            ),
            standardInputFD: nullInput.fileDescriptor,
            standardOutputFD: output.fileHandleForWriting.fileDescriptor,
            standardErrorFD: nullError.fileDescriptor
        )
        try output.fileHandleForWriting.close()

        XCTAssertEqual(result, .exited(17))
        XCTAssertEqual(
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            "fd-secret"
        )
    }
    private func assertRuntimeCancellation(_ disconnect: RuntimeDisconnect) throws {
        let socketPath = try makeSocketPath()
        let started = expectation(description: "runtime accepted request")
        let returned = expectation(description: "runtime returned")
        let runtime = BrokerTextRuntime(resolveCredentials: { _, _ in
            started.fulfill()
            return .resolved([.init(environmentVariable: "TOKEN", value: "secret")])
        })
        let handler = BrokerRequestHandler(
            catalog: { _ in [] },
            requestStatus: { _, _ in nil },
            textRun: { request, descriptors, cancellation in
                defer { returned.fulfill() }
                return try runtime.run(
                    request,
                    standardInputFD: descriptors.standardInput,
                    standardOutputFD: descriptors.standardOutput,
                    standardErrorFD: descriptors.standardError,
                    controlFD: descriptors.control,
                    cancellation: cancellation
                )
            }
        )
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        addTeardownBlock { server.stop() }
        let clientFD = try connectRaw(to: socketPath)
        var controlPipe: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&controlPipe), 0)
        defer { controlPipe.filter { $0 >= 0 }.forEach { close($0) } }
        let nullInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        let nullOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        let request = BrokerRequest(
            version: BrokerProtocolVersion.current,
            method: "runtime.run",
            textRun: .init(command: ["/bin/sleep", "30"], credentialNames: ["TOKEN"])
        )
        let body = try JSONEncoder().encode(request)
        var frame = Data([
            UInt8((body.count >> 24) & 0xff), UInt8((body.count >> 16) & 0xff),
            UInt8((body.count >> 8) & 0xff), UInt8(body.count & 0xff),
        ])
        frame.append(body)
        let sent = frame.withUnsafeBytes { bytes in
            [nullInput.fileDescriptor, nullOutput.fileDescriptor, nullOutput.fileDescriptor, controlPipe[0]]
                .withUnsafeBufferPointer { descriptors in
                    askkey_send_with_fds(
                        clientFD, bytes.baseAddress, bytes.count,
                        descriptors.baseAddress, descriptors.count
                    )
                }
        }
        XCTAssertEqual(sent, frame.count)
        // Exercise cancellation of an accepted runtime request. Resetting before
        // accept/serve can legitimately reject the socket without calling runtime.
        wait(for: [started], timeout: 2)
        var clientClosed = false
        switch disconnect {
        case .eof:
            close(clientFD)
            clientClosed = true
        case .reset:
            var setting = linger(l_onoff: 1, l_linger: 0)
            XCTAssertEqual(
                setsockopt(clientFD, SOL_SOCKET, SO_LINGER, &setting, socklen_t(MemoryLayout.size(ofValue: setting))),
                0
            )
            close(clientFD)
            clientClosed = true
        case .protocolData:
            var extra: UInt8 = 0xff
            XCTAssertEqual(write(clientFD, &extra, 1), 1)
        }

        wait(for: [returned], timeout: 2)
        if !clientClosed { close(clientFD) }
    }
    private func startClosingServer(socketPath: String, accepted: XCTestExpectation) throws {
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw BrokerSocketError.systemError("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
            socketPath.withCString { strncpy(destination, $0, capacity - 1) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listenFD, 1) == 0 else {
            close(listenFD)
            throw BrokerSocketError.systemError("bind/listen", errno)
        }
        DispatchQueue.global().async {
            let fd = accept(listenFD, nil, nil)
            if fd >= 0 {
                var byte: UInt8 = 0
                _ = read(fd, &byte, 1)
                close(fd)
            }
            close(listenFD)
            accepted.fulfill()
        }
    }
}
