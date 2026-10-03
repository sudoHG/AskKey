import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

extension CodexUserMCPAdapter {
    public func status() -> CodexConnectionStatus {
        do {
            try inspectConfigPath()
            try readBackAskKey()
            try verifyConnection()
            return .connected
        } catch {
            return .notConnected
        }
    }

    func readBackAskKey() throws {
        guard let current = try readConfig()?.text, hasExpectedAskKey(current) else {
            throw CodexUserMCPError.connectionFailed("config")
        }
    }

    private func hasExpectedAskKey(_ text: String) -> Bool {
        guard let entry = try? CodexAskKeyTOML.askKey(in: text) else { return false }
        return entry.enabled && entry.command == helperURL.path && entry.args == ["mcp"]
    }

    func assertTrustedHelper() throws {
        if !signing.isTrusted(helperURL) || isSymlink(helperURL)
            || !FileManager.default.isExecutableFile(atPath: helperURL.path) {
            throw CodexUserMCPError.connectionFailed("helper")
        }
    }

    func verifyConnection() throws {
        try assertTrustedHelper()
        do {
            let client = BrokerSocketClient(socketPath: brokerSocketPath)
            let health = try client.send(.init(version: BrokerProtocolVersion.current, method: "health"))
            guard case .success(.health(let payload)) = health, payload.status == "ok" else {
                throw CodexUserMCPError.connectionFailed("broker")
            }
            let version = try client.send(.init(version: BrokerProtocolVersion.current, method: "version"))
            guard case .success(.version(let payload)) = version,
                  payload.protocolVersion == BrokerProtocolVersion.current else {
                throw CodexUserMCPError.connectionFailed("version")
            }
        } catch let error as CodexUserMCPError {
            throw error
        } catch {
            throw CodexUserMCPError.connectionFailed("broker")
        }
        try verifyHelperMCP()
    }

    private func verifyHelperMCP() throws {
        var identity = MCPHelperContract.Identity.askKeyHelper
        if requiresCredentialDiscovery {
            identity.requiredTools.insert("credential_discovery_guard")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["ASKKEY_BROKER_SOCKET"] = brokerSocketPath
        let response: String
        do {
            response = try runProcess(
                executable: helperURL,
                arguments: ["mcp"],
                environment: environment,
                standardInput: try MCPHelperContract.requestPayload(identity)
            )
        } catch {
            throw CodexUserMCPError.connectionFailed("protocol")
        }
        do {
            _ = try MCPHelperContract.inspect(response, identity: identity)
        } catch {
            throw CodexUserMCPError.connectionFailed("protocol")
        }
    }
}
