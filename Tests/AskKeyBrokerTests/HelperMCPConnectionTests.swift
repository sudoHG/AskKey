import XCTest
@testable import AskKeyBroker
import Darwin

final class HelperMCPConnectionTests: HelperMCPTestCase {
    func testMCPConnectionStatusTracksBrokerDisconnectAndReconnect() throws {
        let directory = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("ak-mc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("broker.sock").path

        let (process, input, output) = try startMCPHelper(socketPath: socketPath)

        XCTAssertEqual(
            try connectionStatus(processInput: input, processOutput: output, id: 1)["status"] as? String,
            "broker_unavailable"
        )
        let unavailable = try callMCPTool(
            processInput: input,
            processOutput: output,
            id: 10,
            name: "list_credentials"
        )
        XCTAssertEqual((unavailable["result"] as? [String: Any])?["isError"] as? Bool, true)
        let unavailableStatus = try JSONSerialization.jsonObject(
            with: Data(mcpText(unavailable).utf8)
        ) as? [String: Any]
        XCTAssertEqual(unavailableStatus?["status"] as? String, "broker_unavailable")

        var server: BrokerSocketServer? = try startHealthServer(socketPath: socketPath)
        var status = try connectionStatus(processInput: input, processOutput: output, id: 2)
        XCTAssertEqual(status["status"] as? String, "connected")
        XCTAssertEqual(status["helperVersion"] as? String, AskKeyVersion.current)
        XCTAssertEqual(status["mcpProtocolVersion"] as? String, "2024-11-05")
        XCTAssertEqual(status["brokerProtocolVersion"] as? Int, BrokerProtocolVersion.current)

        server?.stop()
        server = nil
        XCTAssertEqual(
            try connectionStatus(processInput: input, processOutput: output, id: 3)["status"] as? String,
            "broker_unavailable"
        )

        server = try startHealthServer(socketPath: socketPath)
        status = try connectionStatus(processInput: input, processOutput: output, id: 4)
        XCTAssertEqual(status["status"] as? String, "connected")
        server?.stop()
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testMCPConnectionStatusReportsProtocolIncompatibility() throws {
        let directory = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("ak-mv-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let replied = expectation(description: "incompatible broker replied")
        try startResponseServer(
            socketPath: socketPath,
            responses: [.success(.version(.init(protocolVersion: BrokerProtocolVersion.current + 1)))],
            replied: replied
        )

        let (process, input, output) = try startMCPHelper(socketPath: socketPath)

        let status = try connectionStatus(processInput: input, processOutput: output, id: 1)
        XCTAssertEqual(status["status"] as? String, "protocol_incompatible")
        XCTAssertEqual(status["helperProtocolVersion"] as? Int, BrokerProtocolVersion.current)
        XCTAssertEqual(status["brokerProtocolVersion"] as? Int, BrokerProtocolVersion.current + 1)
        wait(for: [replied], timeout: 2)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testMCPConnectionStatusRejectsMismatchedHealthVersion() throws {
        let directory = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("ak-mh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let replied = expectation(description: "mismatched health replied")
        try startResponseServer(
            socketPath: socketPath,
            responses: [
                .success(.version(.init(protocolVersion: BrokerProtocolVersion.current))),
                .success(.health(.init(version: BrokerProtocolVersion.current + 1, status: "ok"))),
            ],
            replied: replied
        )
        let (process, input, output) = try startMCPHelper(socketPath: socketPath)

        let status = try connectionStatus(processInput: input, processOutput: output, id: 1)
        XCTAssertEqual(status["status"] as? String, "protocol_incompatible")
        XCTAssertEqual(status["brokerProtocolVersion"] as? Int, BrokerProtocolVersion.current + 1)
        wait(for: [replied], timeout: 2)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testMCPToolReportsBrokerDisconnectWithoutResponse() throws {
        let directory = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("ak-md-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let disconnected = expectation(description: "broker disconnected")
        try startResponseServer(socketPath: socketPath, responses: [nil], replied: disconnected)
        let (process, input, output) = try startMCPHelper(socketPath: socketPath)

        let failure = try callMCPTool(
            processInput: input,
            processOutput: output,
            id: 1,
            name: "list_credentials"
        )
        let status = try JSONSerialization.jsonObject(
            with: Data(mcpText(failure).utf8)
        ) as? [String: Any]
        XCTAssertEqual(status?["status"] as? String, "broker_disconnected")
        wait(for: [disconnected], timeout: 2)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
