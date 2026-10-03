import Foundation
import CoreFoundation
import AskKeyBroker

let helperVersion = "0.1.0"
let mcpProtocolVersion = "2024-11-05"

func runMCP() throws {
    let client = BrokerSocketClient(socketPath: try BrokerConfiguration.resolvedSocketURL().path)
    let discoveryGuard = CredentialDiscoveryGuard()
    while true {
        var frame: Data
        switch readMCPFrame(maximumBytes: BrokerLimits.maximumFrameBytes) {
        case .frame(let data): frame = data
        case .tooLarge:
            try writeMCPResponse(mcpFailure(id: nil, code: -32600, message: "Request exceeds the fixed size limit"))
            continue
        case .end: return
        case .failure(let code):
            throw BrokerSocketError.systemError("read", code)
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: frame, options: [.fragmentsAllowed])
        } catch {
            frame.resetBytes(in: frame.startIndex..<frame.endIndex)
            try writeMCPResponse(mcpFailure(id: nil, code: -32700, message: "Parse error"))
            continue
        }
        frame.resetBytes(in: frame.startIndex..<frame.endIndex)
        guard let request = json as? [String: Any],
              request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String,
              !method.isEmpty else {
            try writeMCPResponse(mcpFailure(id: nil, code: -32600, message: "Invalid Request"))
            continue
        }
        if let id = request["id"], !validMCPID(id) {
            try writeMCPResponse(mcpFailure(id: nil, code: -32600, message: "Invalid Request"))
            continue
        }
        guard request.keys.contains("id") else { continue }
        let id = request["id"]
        let response: [String: Any]
        switch method {
        case "initialize":
            response = mcpSuccess(id: id, result: [
                "protocolVersion": mcpProtocolVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "askkey", "version": helperVersion],
                "instructions": AgentUsageGuide.instructions,
            ])
        case "tools/list":
            response = mcpSuccess(id: id, result: ["tools": mcpToolDefinitions])
        case "tools/call":
            let params = request["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            do {
                response = try callMCPTool(id: id, name: name, arguments: arguments, client: client, discoveryGuard: discoveryGuard)
            } catch {
                response = try mcpToolFailure(id: id, error: error)
            }
        case "ping":
            response = mcpSuccess(id: id, result: [:])
        default:
            response = mcpFailure(id: id, code: -32601, message: "Method not found")
        }
        try writeMCPResponse(response)
    }
}

private func validMCPID(_ id: Any) -> Bool {
    if id is String || id is NSNull { return true }
    guard let number = id as? NSNumber else { return false }
    return CFGetTypeID(number) != CFBooleanGetTypeID()
}
