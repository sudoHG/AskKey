import Foundation
import AskKeyBroker

struct MCPCredentialCatalog: Encodable {
    let credentials: [BrokerCatalogItem]
    let groups: [String]
}

func parseMCPOrganization(_ arguments: [String: Any]) -> [BrokerOrganizationOperation]? {
    guard Set(arguments.keys).isSubset(of: ["operations", "operation_id", "request_id", "capability", "caller_name", "caller_purpose"]),
          let raw = arguments["operations"] as? [[String: Any]], !raw.isEmpty, raw.count <= 64,
          arguments["operation_id"] is String,
          ["request_id", "capability", "caller_name", "caller_purpose"].allSatisfy({ arguments[$0] == nil || arguments[$0] is String }) else { return nil }
    var operations: [BrokerOrganizationOperation] = []
    for item in raw {
        guard item.count == 1 else { return nil }
        if let move = item["move"] as? [String: Any], Set(move.keys) == ["credential", "group"],
           let credential = move["credential"] as? String {
            if move["group"] is NSNull { operations.append(.move(credential: credential, group: nil)) }
            else if let group = move["group"] as? String { operations.append(.move(credential: credential, group: group)) }
            else { return nil }
        } else if let name = item["create_group"] as? String {
            operations.append(.createGroup(name))
        } else if let rename = item["rename_group"] as? [String: Any], Set(rename.keys) == ["from", "to"],
                  let from = rename["from"] as? String, let to = rename["to"] as? String {
            operations.append(.renameGroup(from: from, to: to))
        } else if let name = item["delete_group"] as? String {
            operations.append(.deleteGroup(name))
        } else { return nil }
    }
    let request = AgentTextWriteRequest(operationID: arguments["operation_id"] as! String,
        action: .organize(operations), callerName: arguments["caller_name"] as? String,
        callerPurpose: arguments["caller_purpose"] as? String)
    return request.isBounded ? operations : nil
}

func organizationMCPToolDefinition() -> [String: Any] {
    func operation(_ key: String, _ value: [String: Any]) -> [String: Any] {
        ["type": "object", "additionalProperties": false, "properties": [key: value], "required": [key]]
    }
    let move: [String: Any] = ["type": "object", "additionalProperties": false,
        "properties": ["credential": ["type": "string"], "group": ["type": ["string", "null"]]],
        "required": ["credential", "group"]]
    let rename: [String: Any] = ["type": "object", "additionalProperties": false,
        "properties": ["from": ["type": "string"], "to": ["type": "string"]], "required": ["from", "to"]]
    return ["name": "organize_credentials", "description": AgentUsageGuide.organizationWrites,
        "inputSchema": ["type": "object", "additionalProperties": false, "properties": [
            "operation_id": ["type": "string"], "request_id": ["type": "string"], "capability": ["type": "string"],
            "caller_name": ["type": "string"], "caller_purpose": ["type": "string"],
            "operations": ["type": "array", "minItems": 1, "maxItems": 64, "items": ["oneOf": [
                operation("move", move), operation("create_group", ["type": "string"]),
                operation("rename_group", rename), operation("delete_group", ["type": "string"])]]]],
            "required": ["operation_id", "operations"]]]
}
