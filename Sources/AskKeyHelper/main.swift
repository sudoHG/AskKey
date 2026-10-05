import Foundation
import CoreFoundation
import AskKeyBroker

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw HelperError.usage }
    if command == "hook" {
        guard arguments.count == 2 else { throw HelperError.usage }
        if arguments[1] == "capabilities" {
            try writeMCPResponse(["protocolVersion": 1, "clients": ["cursor", "grok", "claude", "codex"]])
            exit(EXIT_SUCCESS)
        }
        guard ["cursor", "grok", "claude", "codex"].contains(arguments[1]) else { throw HelperError.usage }
        var response = CommandDiscoveryHook.allow(client: arguments[1])
        let data: Data?
        if arguments[1] == "claude" || arguments[1] == "codex" {
            data = CommandDiscoveryHook.readClaudeInput(maximumBytes: BrokerLimits.maximumFrameBytes)
        } else if case .frame(let frame) = readMCPFrame(maximumBytes: BrokerLimits.maximumFrameBytes) {
            data = frame
        } else { data = nil }
        if let data,
           let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Discovery is a reminder. Invalid input or unavailable ephemeral
            // state cannot authorize a credential or block unrelated work.
            response = (try? CommandDiscoveryHook.response(client: arguments[1], input: input)) ?? response
        }
        if !["claude", "codex"].contains(arguments[1]) || !response.isEmpty { try writeMCPResponse(response) }
        exit(EXIT_SUCCESS)
    }
    if command == "mcp" {
        guard arguments.count == 1 else { throw HelperError.usage }
        try runMCP()
        exit(EXIT_SUCCESS)
    }
    if command == "open" {
        guard arguments.count == 1 else { throw HelperError.usage }
        try openHostApplication()
        exit(EXIT_SUCCESS)
    }
    if command == "run" {
        var credentials: [String] = []
        var operationID = UUID().uuidString
        var callerName: String?
        var callerPurpose: String?
        var waitForApproval = false
        var index = 1
        while index < arguments.count, arguments[index] != "--" {
            if arguments[index] == "--wait-for-approval" {
                waitForApproval = true
                index += 1
                continue
            }
            guard index + 1 < arguments.count else { throw HelperError.usage }
            switch arguments[index] {
            case "--credential": credentials.append(arguments[index + 1])
            case "--operation-id": operationID = arguments[index + 1]
            case "--caller-name": callerName = arguments[index + 1]
            case "--caller-purpose": callerPurpose = arguments[index + 1]
            default: throw HelperError.usage
            }
            index += 2
        }
        guard index < arguments.count, arguments[index] == "--" else { throw HelperError.usage }
        let target = Array(arguments.dropFirst(index + 1))
        let client = BrokerSocketClient(socketPath: try BrokerConfiguration.resolvedSocketURL().path)
        let request = BrokerTextRunRequest(
            operationID: operationID,
            command: target,
            credentialNames: credentials,
            workingDirectory: FileManager.default.currentDirectoryPath,
            inheritedEnvironment: BrokerTextRunRequest.filteredInheritedEnvironment(
                ProcessInfo.processInfo.environment
            ),
            callerName: callerName,
            callerPurpose: callerPurpose
        )
        let result: BrokerTextRunResult
        if waitForApproval {
            result = try runWaitingForApproval(request, using: client)
        } else {
            result = try client.run(request, forwardSignals: true)
        }
        switch result {
        case .exited(let code): exit(code)
        case .outcomeUnknown:
            try FileHandle.standardError.write(contentsOf: Data(
                "Ask Key could not determine whether the target started; it was not retried.\n".utf8
            ))
            exit(EXIT_FAILURE)
        case .approvalRequired:
            var output = try JSONEncoder().encode(result)
            output.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: output)
            throw HelperError.approvalRequired
        }
    }
    guard ["health", "version", "status"].contains(command), arguments.count == 1 else {
        throw HelperError.usage
    }
    let request = BrokerRequest(
        version: BrokerProtocolVersion.current,
        method: command == "status" ? "version" : command
    )
    let response = try BrokerSocketClient(socketPath: try BrokerConfiguration.resolvedSocketURL().path).send(request)
    var output = try JSONEncoder().encode(response)
    output.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: output)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(EXIT_FAILURE)
}
