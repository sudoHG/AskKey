import XCTest
@testable import AskKeyBroker
import Darwin

class HelperApprovalWaitTestCase: XCTestCase {
    func makeListeningSocket(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BrokerSocketError.systemError("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw BrokerSocketError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            let error = errno
            close(descriptor)
            throw BrokerSocketError.systemError("listen", error)
        }
        return descriptor
    }

    func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func startServer(
        socketPath: String,
        state: ApprovalWaitTestState,
        runtime: BrokerTextRuntime,
        beforeRuntime: @escaping @Sendable (BrokerPassedFileDescriptors) -> Void = { _ in },
        beforeStatusResponse: @escaping @Sendable () -> Void = {}
    ) throws -> BrokerSocketServer {
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: .init(
                catalog: { _ in [] },
                requestStatus: { requestID, capability in
                    let result = state.status(requestID: requestID, capability: capability)
                    beforeStatusResponse()
                    return result
                },
                textRun: { request, descriptors, cancellation in
                    beforeRuntime(descriptors)
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
        )
        try server.start()
        return server
    }

    func runHelper(
        socketPath: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> HelperResult {
        let launched = try launchHelper(socketPath: socketPath, arguments: arguments)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while launched.process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if launched.process.isRunning {
            timedOut = true
            launched.process.terminate()
            if !waitForExit(launched.process, timeout: 0.25) {
                _ = Darwin.kill(launched.process.processIdentifier, SIGKILL)
                _ = waitForExit(launched.process, timeout: 1)
            }
        }
        XCTAssertFalse(launched.process.isRunning, "helper process could not be reaped")

        return HelperResult(
            status: launched.process.terminationStatus,
            stdout: launched.output.fileHandleForReading.readDataToEndOfFile(),
            stderr: launched.error.fileHandleForReading.readDataToEndOfFile(),
            timedOut: timedOut
        )
    }

    func launchHelper(
        socketPath: String,
        arguments: [String]
    ) throws -> LaunchedHelper {
        let process = Process()
        process.executableURL = try helperExecutable()
        process.arguments = arguments
        var environment = helperTestEnvironment(overrides: [:])
        environment["ASKKEY_BROKER_SOCKET"] = socketPath
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        try process.run()
        return LaunchedHelper(process: process, output: output, error: error)
    }

    func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }

    func helperExecutable() throws -> URL {
        let executable = Bundle(for: HelperApprovalWaitTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("askkey")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return executable
    }
}
