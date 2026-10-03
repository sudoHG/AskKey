import XCTest
@testable import AskKeyBroker
import Darwin

class HelperMCPTestCase: XCTestCase {
    func exchangeMCP(input: Pipe, output: Pipe, object: [String: Any]) throws -> [String: Any] {
        var encoded = try JSONSerialization.data(withJSONObject: object)
        encoded.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: encoded)
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 0x0A { break }
            line.append(byte)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    func helperExecutable() throws -> URL {
        let executable = Bundle(for: HelperMCPTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("askkey")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return executable
    }

    func startMCPHelper(socketPath: String) throws -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = try helperExecutable()
        process.arguments = ["mcp"]
        var environment = helperTestEnvironment(overrides: [:])
        environment["ASKKEY_BROKER_SOCKET"] = socketPath
        environment["ASKKEY_UNRELATED_TEST_VALUE"] = "must-not-cross-helper-boundary"
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        addTeardownBlock {
            if process.isRunning { process.terminate() }
        }
        return (process, input, output)
    }

    func mcpText(_ response: [String: Any]) throws -> String {
        guard let result = response["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw CocoaError(.coderReadCorrupt)
        }
        return text
    }

    func startHealthServer(socketPath: String) throws -> BrokerSocketServer {
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        )
        try server.start()
        return server
    }

    func connectionStatus(processInput: Pipe, processOutput: Pipe, id: Int) throws -> [String: Any] {
        let response = try callMCPTool(
            processInput: processInput,
            processOutput: processOutput,
            id: id,
            name: "connection_status"
        )
        guard let text = try? mcpText(response),
              let status = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return status
    }

    func callMCPTool(
        processInput: Pipe,
        processOutput: Pipe,
        id: Int,
        name: String
    ) throws -> [String: Any] {
        let request = """
        {"jsonrpc":"2.0","id":\(id),"method":"tools/call","params":{"name":"\(name)","arguments":{}}}
        """
        try processInput.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))
        let line = processOutput.fileHandleForReading.availableData
        guard !line.isEmpty,
              let response = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return response
    }

    func startResponseServer(
        socketPath: String,
        responses: [BrokerResponse?],
        replied: XCTestExpectation
    ) throws {
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw BrokerSocketError.systemError("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else { throw BrokerSocketError.pathTooLong }
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
            defer { close(listenFD); replied.fulfill() }
            for response in responses {
                let fd = accept(listenFD, nil, nil)
                guard fd >= 0 else { return }
                defer { close(fd) }
                var header = Data(count: 4)
                guard Self.readAll(fd: fd, into: &header) else { return }
                let length = header.reduce(0) { ($0 << 8) | Int($1) }
                var body = Data(count: length)
                guard Self.readAll(fd: fd, into: &body) else { return }
                guard let response,
                      let encoded = try? JSONEncoder().encode(response) else { continue }
                var frame = Data([
                    UInt8((encoded.count >> 24) & 0xff), UInt8((encoded.count >> 16) & 0xff),
                    UInt8((encoded.count >> 8) & 0xff), UInt8(encoded.count & 0xff),
                ])
                frame.append(encoded)
                XCTAssertTrue(Self.writeAll(fd: fd, data: frame))
            }
        }
    }

    static func readAll(fd: Int32, into data: inout Data) -> Bool {
        data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return bytes.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = read(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return bytes.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}
