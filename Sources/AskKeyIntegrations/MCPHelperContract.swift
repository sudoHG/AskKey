import Foundation
import AskKeyBroker

/// Shared initialize + tools/list request and response checks.
/// Codex, Cursor, and Grok keep their own clientInfo and runner.
enum MCPHelperContract {
    struct Identity: Equatable, Sendable {
        var clientName: String
        var clientVersion: String
        var serverName: String
        var serverVersion: String
        var protocolVersion: String = "2024-11-05"
        var requiredTools: Set<String> = ["list_credentials", "run"]

        static let askKeyHelper = Identity(
            clientName: "askkey",
            clientVersion: AskKeyVersion.current,
            serverName: "askkey",
            serverVersion: AskKeyVersion.current
        )

        static let grokClient = Identity(
            clientName: "askkey",
            clientVersion: "0",
            serverName: "askkey",
            serverVersion: AskKeyVersion.current
        )

        static let cursorClient = Identity(
            clientName: "cursor",
            clientVersion: "0",
            serverName: "askkey",
            serverVersion: AskKeyVersion.current
        )
    }

    struct Inspection: Equatable, Sendable {
        var version: String
        var tools: [String]
    }

    enum Failure: Error, Equatable {
        case malformed
        case unexpectedIdentity
        case missingTools
    }

    static func requestPayload(_ identity: Identity) throws -> Data {
        let requests: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": identity.protocolVersion,
                    "capabilities": [String: Any](),
                    "clientInfo": [
                        "name": identity.clientName,
                        "version": identity.clientVersion,
                    ],
                ],
            ],
            [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
                "params": [String: Any](),
            ],
        ]
        var payload = Data()
        for request in requests {
            payload.append(try JSONSerialization.data(withJSONObject: request))
            payload.append(0x0A)
        }
        return payload
    }

    static func inspect(_ response: String, identity: Identity) throws -> Inspection {
        let lines = response.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2 else { throw Failure.malformed }
        let initialize = try resultObject(lines[0], id: 1)
        guard let protocolVersion = initialize["protocolVersion"] as? String,
              let serverInfo = initialize["serverInfo"] as? [String: Any],
              let name = serverInfo["name"] as? String,
              let version = serverInfo["version"] as? String else {
            throw Failure.malformed
        }
        guard protocolVersion == identity.protocolVersion,
              name == identity.serverName,
              version == identity.serverVersion else {
            throw Failure.unexpectedIdentity
        }
        let listed = try resultObject(lines[1], id: 2)
        guard let tools = listed["tools"] as? [[String: Any]] else {
            throw Failure.malformed
        }
        let names = Set(tools.compactMap { $0["name"] as? String })
        guard names.isSuperset(of: identity.requiredTools) else {
            throw Failure.missingTools
        }
        return Inspection(version: version, tools: Array(names).sorted())
    }
}

private func resultObject(_ line: String, id: Int) throws -> [String: Any] {
    guard let data = line.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["jsonrpc"] as? String == "2.0",
          jsonRPCID(object["id"]) == id,
          object["error"] == nil,
          let result = object["result"] as? [String: Any] else {
        throw MCPHelperContract.Failure.malformed
    }
    return result
}

private func jsonRPCID(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else {
        return nil
    }
    let doubleValue = number.doubleValue
    let intValue = number.intValue
    guard doubleValue.isFinite, Double(intValue) == doubleValue else { return nil }
    return intValue
}
