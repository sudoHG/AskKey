import Foundation
import AskKeyBroker

extension ClaudeCodeMCPAdapter {
    func verify(version: String) throws -> ClaudeCodeMCPConnectionStatus {
        func status(_ reason: String, helperVersion: String = "") -> ClaudeCodeMCPConnectionStatus {
            ClaudeCodeMCPConnectionStatus(
                connected: reason == "ok", reason: reason, version: version, helperVersion: helperVersion
            )
        }
        let entry = try inspectEntry()
        guard entry.state == .matching else { return status("configuration_mismatch") }
        guard entry.connected else { return status("client_disconnected") }
        guard signing.isTrusted(helperURL) else { return status("helper_signature") }
        let helper = try run(
            executable: helperURL, arguments: ["mcp"],
            input: MCPHelperContract.requestPayload(.claudeClient)
        )
        guard helper.status == 0,
              let inspected = try? MCPHelperContract.inspect(
                String(decoding: helper.stdout, as: UTF8.self), identity: .claudeClient
              ) else { return status("helper_contract") }
        let health = try run(executable: helperURL, arguments: ["health"])
        guard health.status == 0,
              let decoded = try? JSONDecoder().decode(BrokerResponse.self, from: health.stdout),
              case .success(.health(let payload)) = decoded,
              payload.status == "ok", payload.version == BrokerProtocolVersion.current else {
            return status("broker_unhealthy", helperVersion: inspected.version)
        }
        return status("ok", helperVersion: inspected.version)
    }
}
