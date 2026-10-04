import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker
import CryptoKit

extension GrokCLIAdapter {
    public func status() throws -> GrokCLIConnectResult {
        try prepareIsolatedHome()
        try inspectConfigFile()
        let original = try readOriginal()
        if let text = original.text {
            try validateUserTOML(text)
            if GrokUserTOML.askKeyTransport(in: text) == .remote {
                return GrokCLIConnectResult(
                    connected: false,
                    reason: "remote_connector",
                    diff: "",
                    listJSON: "",
                    doctorJSON: "",
                    helperVersion: ""
                )
            }
        }
        return try verify(before: original.text ?? "")
    }

    func verify(before: String) throws -> GrokCLIConnectResult {
        let after = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let diff = GrokUserTOML.redactedDiff(before: before, after: after)
        if GrokUserTOML.askKeyTransport(in: after) == .remote {
            return result(connected: false, reason: "remote_connector", diff: diff, listJSON: "", doctorJSON: "", version: "")
        }
        if GrokUserTOML.askKeyTransport(in: after) != .stdio(command: helperExecutable.path, args: ["mcp"]) {
            return result(connected: false, reason: "not_configured", diff: diff, listJSON: "", doctorJSON: "", version: "")
        }

        guard canUseOfficialGrok() else {
            return result(connected: false, reason: "list_unavailable", diff: diff, listJSON: "", doctorJSON: "", version: "")
        }
        let listed = try runGrok(["mcp", "list", "--json"])
        let listJSON = extractJSON(String(decoding: listed.stdout, as: UTF8.self))
        guard listed.status == 0, let listData = listJSON.data(using: .utf8),
              let servers = try JSONSerialization.jsonObject(with: listData) as? [[String: Any]],
              let askkey = servers.first(where: {
                  $0["name"] as? String == serverName
                      && $0["scope"] as? String != "project"
                      && $0["url"] == nil
              }),
              askkey["command"] as? String == helperExecutable.path,
              (askkey["args"] as? [String]) == ["mcp"] else {
            return result(connected: false, reason: "list_mismatch", diff: diff, listJSON: listJSON, doctorJSON: "", version: "")
        }
        let doctor = try runGrok(["mcp", "doctor", "--json", serverName])
        let doctorJSON = extractJSON(String(decoding: doctor.stdout, as: UTF8.self))
        guard doctor.status == 0, doctorHealthy(doctorJSON) else {
            return result(connected: false, reason: "doctor_unhealthy", diff: diff, listJSON: listJSON, doctorJSON: doctorJSON, version: "")
        }

        guard signing.isTrusted(helperExecutable) else {
            return result(connected: false, reason: "helper_signature", diff: diff, listJSON: listJSON, doctorJSON: doctorJSON, version: "")
        }
        let helper: (version: String, tools: [String])
        do {
            helper = try inspectHelper()
        } catch is MCPHelperContract.Failure {
            return result(
                connected: false,
                reason: "helper_initialize",
                diff: diff,
                listJSON: listJSON,
                doctorJSON: doctorJSON,
                version: ""
            )
        }
        guard helper.version == AskKeyVersion.current else {
            return result(connected: false, reason: "helper_version", diff: diff, listJSON: listJSON, doctorJSON: doctorJSON, version: helper.version)
        }
        guard helper.tools.contains("list_credentials"), helper.tools.contains("run") else {
            return result(connected: false, reason: "helper_tools", diff: diff, listJSON: listJSON, doctorJSON: doctorJSON, version: helper.version)
        }
        guard try brokerIsHealthy() else {
            return result(connected: false, reason: "broker_unhealthy", diff: diff, listJSON: listJSON, doctorJSON: doctorJSON, version: helper.version)
        }
        return result(
            connected: true,
            reason: "ok",
            diff: diff,
            listJSON: listJSON,
            doctorJSON: doctorJSON,
            version: helper.version
        )
    }

    private func result(
        connected: Bool,
        reason: String,
        diff: String,
        listJSON: String,
        doctorJSON: String,
        version: String
    ) -> GrokCLIConnectResult {
        GrokCLIConnectResult(
            connected: connected,
            reason: reason,
            diff: diff,
            listJSON: listJSON,
            doctorJSON: doctorJSON,
            helperVersion: version
        )
    }

    private func doctorHealthy(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["servers"] as? [[String: Any]],
              let askkey = servers.first(where: { $0["name"] as? String == serverName }) else {
            return false
        }
        if askkey["transport"] as? String != "stdio" { return false }
        if let target = askkey["target"] as? String, target.lowercased().hasPrefix("http") { return false }
        return askkey["healthy"] as? Bool == true
    }

    private func inspectHelper() throws -> (version: String, tools: [String]) {
        let ran = try runCapturedProcess(
            executable: helperExecutable,
            arguments: ["mcp"],
            environment: helperProcessEnvironment(),
            currentDirectory: isolatedHome,
            input: try MCPHelperContract.requestPayload(.grokClient),
            timeout: commandTimeout
        )
        guard ran.status == 0 else {
            throw GrokCLIAdapterError.verificationFailed("helper_initialize")
        }
        let inspected = try MCPHelperContract.inspect(
            String(decoding: ran.stdout, as: UTF8.self),
            identity: .grokClient
        )
        return (inspected.version, inspected.tools)
    }

    private func brokerIsHealthy() throws -> Bool {
        let ran = try runCapturedProcess(
            executable: helperExecutable,
            arguments: ["health"],
            environment: helperProcessEnvironment(),
            currentDirectory: isolatedHome,
            timeout: commandTimeout
        )
        guard ran.status == 0 else { return false }
        let trimmed = String(decoding: ran.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return false }
        let decoded = try JSONDecoder().decode(BrokerResponse.self, from: data)
        guard case .success(.health(let health)) = decoded else { return false }
        return health.status == "ok" && health.version == BrokerProtocolVersion.current
    }

}

private func extractJSON(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let objectStart = trimmed.firstIndex(of: "{")
    let arrayStart = trimmed.firstIndex(of: "[")
    switch (objectStart, arrayStart) {
    case let (object?, array?) where array < object:
        if let end = trimmed.lastIndex(of: "]") { return String(trimmed[array...end]) }
    case let (object?, _):
        if let end = trimmed.lastIndex(of: "}") { return String(trimmed[object...end]) }
    case let (nil, array?):
        if let end = trimmed.lastIndex(of: "]") { return String(trimmed[array...end]) }
    default:
        break
    }
    return trimmed
}
