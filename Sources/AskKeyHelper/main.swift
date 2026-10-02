import Foundation
import CoreFoundation
import AskKeyBroker

enum HelperError: Error, LocalizedError {
    case usage
    case approvalRequired

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: askkey health | version | status | mcp | open | run --credential <name> [--credential <name> ...] [--wait-for-approval] [--operation-id <id>] [--caller-name <name>] [--caller-purpose <purpose>] -- <command> [args...]"
        case .approvalRequired:
            return "Ask Key approval is required. Retry with the same --operation-id after approval."
        }
    }
}

private let helperVersion = "0.1.0"
private let mcpProtocolVersion = "2024-11-05"

private func runMCP() throws {
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

private enum MCPFrameRead {
    case frame(Data)
    case tooLarge
    case end
    case failure(Int32)
}

private func readMCPFrame(maximumBytes: Int) -> MCPFrameRead {
    var frame = Data()
    var oversized = false
    while true {
        var byte: UInt8 = 0
        let count = read(FileHandle.standardInput.fileDescriptor, &byte, 1)
        if count < 0, errno == EINTR { continue }
        if count < 0 { return .failure(errno) }
        if count == 0 {
            if oversized { return .tooLarge }
            return frame.isEmpty ? .end : .frame(frame)
        }
        if byte == 0x0A { return oversized ? .tooLarge : .frame(frame) }
        if frame.count >= maximumBytes {
            oversized = true
        } else if !oversized {
            frame.append(byte)
        }
    }
}

private func writeMCPResponse(_ response: [String: Any]) throws {
    var output = try JSONSerialization.data(withJSONObject: response)
    output.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: output)
}

private func callMCPTool(
    id: Any?,
    name: String,
    arguments: [String: Any],
    client: BrokerSocketClient,
    discoveryGuard: CredentialDiscoveryGuard
) throws -> [String: Any] {
    switch name {
    case "credential_discovery_guard":
        let output = try JSONSerialization.data(withJSONObject: discoveryGuard.response(to: arguments))
        return mcpToolText(id: id, text: String(decoding: output, as: UTF8.self))
    case "connection_status":
        return mcpToolText(id: id, text: try connectionStatus(client: client))
    case "begin_component_upload":
        guard let operationID = arguments["operation_id"] as? String,
              let filename = arguments["filename"] as? String,
              let byteCount = arguments["byte_count"] as? Int else {
            return mcpFailure(id: id, code: -32602, message: "operation_id, filename and byte_count are required")
        }
        let response = try client.send(.init(version: BrokerProtocolVersion.current,
            method: "credential.file.write", fileWrite: .beginComponent(.init(
                operationID: operationID, originalFilename: filename, expectedByteCount: byteCount))))
        return try mcpBrokerResponse(id: id, response: response, expecting: .upload)
    case "freeze_component_upload", "cancel_component_upload":
        guard let uploadID = arguments["upload_id"] as? String,
              let capability = arguments["capability"] as? String else {
            return mcpFailure(id: id, code: -32602, message: "upload_id and capability are required")
        }
        let payload = BrokerFileWriteFreezeRequest(uploadID: uploadID, capability: capability)
        let response = try client.send(.init(version: BrokerProtocolVersion.current,
            method: "credential.file.write", fileWrite: name == "freeze_component_upload"
                ? .freezeComponent(payload) : .cancelUpload(payload)))
        return try mcpBrokerResponse(id: id, response: response,
            expecting: name == "freeze_component_upload" ? .component : .cancelled)
    case "create_credential":
        guard let credentialName = arguments["name"] as? String,
              let raw = arguments["components"] as? [[String: Any]],
              let components = parseMCPComponents(raw) else {
            return mcpFailure(id: id, code: -32602, message: "name and valid components are required")
        }
        return try callMCPTextWrite(id: id, action: .createBundle(name: credentialName, components: components),
            arguments: arguments, client: client)
    case "modify_credential":
        guard let credentialName = arguments["name"] as? String,
              let raw = arguments["changes"] as? [[String: Any]], !raw.isEmpty, raw.count <= 64 else {
            return mcpFailure(id: id, code: -32602, message: "name and valid changes are required")
        }
        var changes: [BrokerCredentialComponentChange] = []
        for item in raw {
            if let remove = item["remove"] as? String, item.count == 1 {
                changes.append(.remove(remove))
            } else if let input = item["upsert"] as? [String: Any], item.count == 1,
                      let parsed = parseMCPComponents([input])?.first {
                changes.append(.upsert(parsed))
            } else {
                return mcpFailure(id: id, code: -32602, message: "Each change requires one upsert or remove")
            }
        }
        return try callMCPTextWrite(id: id, action: .modifyBundle(name: credentialName, changes: changes),
            arguments: arguments, client: client)
    case "begin_file_write":
        guard let operationID = arguments["operation_id"] as? String,
              let credentialID = arguments["credential_id"] as? String,
              let targetID = arguments["target_id"] as? String,
              let operationName = arguments["operation"] as? String,
              let operation = BrokerApprovalOperation(rawValue: operationName),
              operation == .create || operation == .modify,
              let filename = arguments["filename"] as? String,
              let byteCount = arguments["byte_count"] as? Int else {
            return mcpFailure(id: id, code: -32602, message: "Invalid file write begin request")
        }
        let response = try client.send(.init(
            version: BrokerProtocolVersion.current,
            method: "credential.file.write",
            fileWrite: .begin(.init(
                operationID: operationID,
                credentialID: credentialID,
                targetID: targetID,
                operation: operation,
                originalFilename: filename,
                expectedByteCount: byteCount
            ))
        ))
        return try mcpBrokerResponse(id: id, response: response, expecting: .upload)
    case "append_file_write", "append_component_upload":
        guard let uploadID = arguments["upload_id"] as? String,
              let capability = arguments["capability"] as? String,
              let offset = arguments["offset"] as? Int,
              let base64 = arguments["chunk_base64"] as? String,
              var bytes = Data(base64Encoded: base64),
              !bytes.isEmpty,
              bytes.count <= BrokerFileWriteCoordinator.maximumChunkByteCount else {
            return mcpFailure(id: id, code: -32602, message: "Invalid bounded file write chunk")
        }
        defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
        let response = try client.send(.init(
            version: BrokerProtocolVersion.current,
            method: "credential.file.write",
            fileWrite: .append(.init(
                uploadID: uploadID,
                capability: capability,
                offset: offset,
                bytes: bytes
            ))
        ))
        return try mcpBrokerResponse(id: id, response: response, expecting: .chunk)
    case "freeze_file_write":
        guard let uploadID = arguments["upload_id"] as? String,
              let capability = arguments["capability"] as? String else {
            return mcpFailure(id: id, code: -32602, message: "Invalid file write freeze request")
        }
        let response = try client.send(.init(
            version: BrokerProtocolVersion.current,
            method: "credential.file.write",
            fileWrite: .freeze(.init(uploadID: uploadID, capability: capability))
        ))
        return try mcpBrokerResponse(id: id, response: response, expecting: .approval)
    case "create_text_credential":
        guard let name = arguments["name"] as? String,
              let value = arguments["value"] as? String else {
            return mcpFailure(id: id, code: -32602, message: "name and value are required")
        }
        return try callMCPTextWrite(
            id: id,
            action: .create(name: name, value: value),
            arguments: arguments,
            client: client
        )
    case "modify_text_credential":
        guard let name = arguments["name"] as? String,
              let value = arguments["value"] as? String else {
            return mcpFailure(id: id, code: -32602, message: "name and value are required")
        }
        return try callMCPTextWrite(
            id: id,
            action: .modify(name: name, value: value),
            arguments: arguments,
            client: client
        )
    case "delete_credential":
        guard let name = arguments["name"] as? String else {
            return mcpFailure(id: id, code: -32602, message: "name is required")
        }
        return try callMCPTextWrite(
            id: id,
            action: .delete(name: name),
            arguments: arguments,
            client: client
        )
    case "request_status", "request_cancel":
        guard let requestID = arguments["request_id"] as? String,
              let capability = arguments["capability"] as? String else {
            return mcpFailure(id: id, code: -32602, message: "request_id and capability are required")
        }
        let response = try client.send(.init(
            version: BrokerProtocolVersion.current,
            method: name == "request_status" ? "request.status" : "request.cancel",
            requestID: requestID,
            capability: capability
        ))
        return try mcpRequestStateResponse(id: id, response: response)
    case "list_credentials":
        // Release the reminder only after a real lookup attempt has finished,
        // including an unavailable Broker, so parallel calls cannot jump ahead.
        defer { discoveryGuard.catalogAttemptFinished(token: arguments["discovery_token"] as? String) }
        let response = try client.send(.init(version: BrokerProtocolVersion.current, method: "catalog"))
        guard case .success(.catalog(let items)) = response else {
            if case .failure(let code) = response {
                return try mcpBrokerFailure(id: id, code: code)
            }
            return try mcpStatusError(id: id, status: "unexpected_response")
        }
        let encoded = try JSONEncoder().encode(items)
        return mcpToolText(id: id, text: String(decoding: encoded, as: UTF8.self), guidance: AgentUsageGuide.catalogDescription)
    case "run":
        guard let credentials = arguments["credentials"] as? [String], !credentials.isEmpty,
              let command = arguments["command"] as? [String], !command.isEmpty else {
            return mcpFailure(id: id, code: -32602, message: "credentials and command are required")
        }
        let nullInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        let nullOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        let result = try client.run(
            .init(
                operationID: arguments["operation_id"] as? String ?? UUID().uuidString,
                command: command,
                credentialNames: credentials,
                workingDirectory: arguments["cwd"] as? String,
                inheritedEnvironment: BrokerTextRunRequest.filteredInheritedEnvironment(
                    ProcessInfo.processInfo.environment
                ),
                callerName: arguments["caller_name"] as? String,
                callerPurpose: arguments["caller_purpose"] as? String
            ),
            standardInputFD: nullInput.fileDescriptor,
            standardOutputFD: nullOutput.fileDescriptor,
            standardErrorFD: nullOutput.fileDescriptor
        )
        let encoded = try JSONEncoder().encode(result)
        return mcpToolText(id: id, text: String(decoding: encoded, as: UTF8.self), guidance: AgentUsageGuide.nextStep(for: result))
    default:
        return mcpFailure(id: id, code: -32602, message: "Unknown tool: \(name)")
    }
}

private func callMCPTextWrite(
    id: Any?,
    action: AgentTextWriteAction,
    arguments: [String: Any],
    client: BrokerSocketClient
) throws -> [String: Any] {
    guard let operationID = arguments["operation_id"] as? String else {
        return mcpFailure(id: id, code: -32602, message: "operation_id is required")
    }
    let request = AgentTextWriteRequest(
        operationID: operationID,
        action: action,
        callerName: arguments["caller_name"] as? String,
        callerPurpose: arguments["caller_purpose"] as? String
    )
    let requestID = arguments["request_id"] as? String
    let capability = arguments["capability"] as? String
    let brokerRequest: BrokerRequest
    switch (requestID, capability) {
    case (nil, nil):
        brokerRequest = .init(
            version: BrokerProtocolVersion.current,
            method: "credential.write.request",
            textWrite: request
        )
    case let (requestID?, capability?):
        brokerRequest = .init(
            version: BrokerProtocolVersion.current,
            method: "credential.write.commit",
            requestID: requestID,
            capability: capability,
            textWrite: request
        )
    default:
        return mcpFailure(id: id, code: -32602, message: "request_id and capability must be supplied together")
    }
    return try mcpTextWriteResponse(id: id, response: client.send(brokerRequest))
}

private func mcpTextWriteResponse(id: Any?, response: BrokerResponse) throws -> [String: Any] {
    switch response {
    case .success(.textWriteRequest), .success(.textWriteResult):
        let encoded = try JSONEncoder().encode(response)
        return mcpToolText(id: id, text: String(decoding: encoded, as: UTF8.self))
    case .failure(let code):
        return try mcpBrokerFailure(id: id, code: code)
    default:
        return try mcpStatusError(id: id, status: "unexpected_response")
    }
}

private func mcpRequestStateResponse(id: Any?, response: BrokerResponse) throws -> [String: Any] {
    switch response {
    case .success(.requestStatus):
        let encoded = try JSONEncoder().encode(response)
        return mcpToolText(id: id, text: String(decoding: encoded, as: UTF8.self))
    case .failure(let code):
        return try mcpBrokerFailure(id: id, code: code)
    default:
        return try mcpStatusError(id: id, status: "unexpected_response")
    }
}

private func textWriteToolDefinition(
    name: String,
    description: String,
    requiresValue: Bool
) -> [String: Any] {
    var properties: [String: Any] = [
        "operation_id": ["type": "string"],
        "name": ["type": "string"],
        "caller_name": ["type": "string"],
        "caller_purpose": ["type": "string"],
        "request_id": ["type": "string"],
        "capability": ["type": "string"],
    ]
    var required = ["operation_id", "name"]
    if requiresValue {
        properties["value"] = ["type": "string"]
        required.append("value")
    }
    return [
        "name": name,
        "description": description,
        "inputSchema": [
            "type": "object",
            "properties": properties,
            "required": required,
        ],
    ]
}

private let mcpToolDefinitions: [[String: Any]] = componentMCPToolDefinitions() + [
    [
        "name": "credential_discovery_guard",
        "description": "Client adapter lifecycle hook for PreToolUse credential discovery. Configure as a native MCP tool hook; not a credential lookup or access tool. Does not read secrets or execute commands.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "session_id": ["type": "string"],
                "turn_id": ["type": "string"],
                "tool_name": ["type": "string"],
                "tool_input": ["type": "object"],
            ],
            "required": ["session_id", "turn_id", "tool_name", "tool_input"],
        ],
    ],
    [
        "name": "connection_status",
        "annotations": ["readOnlyHint": true, "openWorldHint": false],
        "description": "Check that this helper can negotiate the local Ask Key Broker protocol.",
        "inputSchema": ["type": "object", "properties": [:]],
    ],
    [
        "name": "begin_file_write",
        "description": "Begin a bounded create or modify request for an Agent-known file value.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "operation_id": ["type": "string"],
                "credential_id": ["type": "string"],
                "target_id": ["type": "string"],
                "operation": ["type": "string", "enum": ["create", "modify"]],
                "filename": ["type": "string"],
                "byte_count": ["type": "integer", "minimum": 0],
            ],
            "required": ["operation_id", "credential_id", "target_id", "operation", "filename", "byte_count"],
        ],
    ],
    [
        "name": "append_file_write",
        "description": "Append one base64-encoded chunk to a file write upload.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "upload_id": ["type": "string"],
                "capability": ["type": "string"],
                "offset": ["type": "integer", "minimum": 0],
                "chunk_base64": ["type": "string"],
            ],
            "required": ["upload_id", "capability", "offset", "chunk_base64"],
        ],
    ],
    [
        "name": "freeze_file_write",
        "description": "Freeze uploaded bytes and create the App approval request.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "upload_id": ["type": "string"],
                "capability": ["type": "string"],
            ],
            "required": ["upload_id", "capability"],
        ],
    ],
    textWriteToolDefinition(
        name: "create_text_credential",
        description: "Request creation of an Agent-known text credential. Re-submit with request_id and capability after approval to commit.",
        requiresValue: true
    ),
    textWriteToolDefinition(
        name: "modify_text_credential",
        description: "Request modification of an Agent-known text credential. Re-submit with request_id and capability after approval to commit.",
        requiresValue: true
    ),
    textWriteToolDefinition(
        name: "delete_credential",
        description: "Request that a credential move to the App recycle bin. Re-submit with request_id and capability after approval to commit.",
        requiresValue: false
    ),
    [
        "name": "request_status",
        "annotations": ["readOnlyHint": true, "openWorldHint": false],
        "description": "Check an existing approval ticket using requestID as request_id and capability. This does not execute or consume it. For run, after approval retry the original run or CLI command with the same operation_id and identical payload. For credential writes, repeat the original write with request_id and capability. Stop on denial, cancellation or expiry.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "request_id": ["type": "string"],
                "capability": ["type": "string"],
            ],
            "required": ["request_id", "capability"],
        ],
    ],
    [
        "name": "request_cancel",
        "description": "Cancel one incomplete approval request using its capability.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "request_id": ["type": "string"],
                "capability": ["type": "string"],
            ],
            "required": ["request_id", "capability"],
        ],
    ],
    [
        "name": "list_credentials",
        "annotations": ["readOnlyHint": true, "openWorldHint": false],
        "description": AgentUsageGuide.catalogDescription,
        "inputSchema": ["type": "object", "properties": [
            "discovery_token": ["type": "string", "description": "Client lifecycle correlation token; omit on manual calls."],
        ]],
    ],
    [
        "name": "run",
        "description": AgentUsageGuide.runDescription,
        "inputSchema": [
            "type": "object",
            "properties": [
                "credentials": ["type": "array", "minItems": 1, "items": ["type": "string"],
                    "description": "Exact visible credential names from list_credentials, not credentialID values. Select only credentials needed for this task."],
                "command": ["type": "array", "minItems": 1, "items": ["type": "string"],
                    "description": "Executable and arguments, not a shell string. Consume the environment variables specified by component delivery mappings; a shell must be explicitly invoked to expand variables. Keep saved values out of argv and output. For command output choose the CLI before starting."],
                "cwd": ["type": "string", "description": "Existing absolute working directory. Keep unchanged when resuming approval."],
                "operation_id": ["type": "string", "description": "Choose a unique ID before starting; keep the same ID and identical request for approval retries. If omitted, preserve the operationID returned by approvalRequired. A new task needs a new ID."],
                "caller_name": ["type": "string"],
                "caller_purpose": ["type": "string"],
            ],
            "required": ["credentials", "command"],
        ],
    ],
]

private func componentMCPToolDefinitions() -> [[String: Any]] {
    let component: [String: Any] = ["type": "object", "additionalProperties": false,
        "properties": [
            "name": ["type": "string"], "text": ["type": "string"],
            "file": ["type": "object", "properties": ["upload_id": ["type": "string"],
                "capability": ["type": "string"], "digest": ["type": "string"]],
                "required": ["upload_id", "capability", "digest"]],
            "delivery": ["type": "object", "properties": [
                "type": ["type": "string", "enum": ["environment_variable", "temporary_file", "none"]],
                "environment_variable": ["type": "string"]], "required": ["type"]],
            "masked": ["type": "boolean"]], "required": ["name", "delivery"],
        "oneOf": [["required": ["text"]], ["required": ["file"]]]]
    func definition(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }
    let common: [String: Any] = ["name": ["type": "string"], "operation_id": ["type": "string"],
        "request_id": ["type": "string"], "capability": ["type": "string"],
        "caller_name": ["type": "string"], "caller_purpose": ["type": "string"]]
    var create = common
    create["components"] = ["type": "array", "minItems": 1, "maxItems": 64, "items": component]
    var modify = common
    modify["changes"] = ["type": "array", "minItems": 1, "maxItems": 64,
        "items": ["type": "object", "oneOf": [
            ["properties": ["upsert": component], "required": ["upsert"], "additionalProperties": false],
            ["properties": ["remove": ["type": "string"]], "required": ["remove"], "additionalProperties": false]]]]
    let upload: [String: Any] = ["upload_id": ["type": "string"], "capability": ["type": "string"]]
    var append = upload
    append["offset"] = ["type": "integer"]
    append["chunk_base64"] = ["type": "string"]
    return [
        definition("create_credential", "Create a whole credential with text/file components under one frozen approval. Files use operation-bound staged references; never local paths.", create, ["name", "operation_id", "components"]),
        definition("modify_credential", "Atomically upsert/remove named components; omitted components and credential metadata are preserved. Repeat exact operation_id and payload with request_id/capability to commit.", modify, ["name", "operation_id", "changes"]),
        definition("begin_component_upload", "Begin encrypted staging for a component in one credential operation.",
            ["operation_id": ["type": "string"], "filename": ["type": "string"], "byte_count": ["type": "integer"]], ["operation_id", "filename", "byte_count"]),
        definition("append_component_upload", "Append a bounded base64 chunk to encrypted component staging.", append, ["upload_id", "capability", "offset", "chunk_base64"]),
        definition("freeze_component_upload", "Freeze staged bytes and return a digest-bound reference for create_credential/modify_credential; this does not approve a write.", upload, ["upload_id", "capability"]),
        definition("cancel_component_upload", "Cancel staging and remove its encrypted temporary payload.", upload, ["upload_id", "capability"]),
    ]
}

private func parseMCPComponents(_ raw: [[String: Any]]) -> [BrokerCredentialComponentInput]? {
    guard !raw.isEmpty, raw.count <= 64 else { return nil }
    var inputs: [BrokerCredentialComponentInput] = []
    for item in raw {
        guard Set(item.keys).isSubset(of: ["name", "text", "file", "delivery", "masked"]),
              let name = item["name"] as? String,
              let mapping = item["delivery"] as? [String: Any],
              let type = mapping["type"] as? String else { return nil }
        let delivery: BrokerComponentDelivery
        switch type {
        case "none":
            guard mapping.count == 1 else { return nil }
            delivery = .none
        case "environment_variable", "temporary_file":
            guard mapping.count == 2, let variable = mapping["environment_variable"] as? String else { return nil }
            delivery = type == "environment_variable" ? .environmentVariable(variable) : .temporaryFile(variable)
        default: return nil
        }
        let value: BrokerCredentialComponentValue
        if let text = item["text"] as? String, item["file"] == nil {
            value = .text(text)
        } else if let file = item["file"] as? [String: Any], item["text"] == nil,
                  file.count == 3, let uploadID = file["upload_id"] as? String,
                  let capability = file["capability"] as? String, let digest = file["digest"] as? String {
            value = .file(.init(uploadID: uploadID, capability: capability, digest: digest))
        } else { return nil }
        if let masked = item["masked"], !(masked is Bool) { return nil }
        inputs.append(.init(name: name, value: value, delivery: delivery, masked: item["masked"] as? Bool ?? true))
    }
    return inputs
}

private enum ExpectedFileWriteResponse: String {
    case upload
    case chunk
    case approval
    case component
    case cancelled

    func matches(_ payload: BrokerFileWritePayload) -> Bool {
        switch (self, payload) {
        case (.upload, .upload), (.chunk, .chunkAccepted), (.approval, .approval),
             (.component, .componentFrozen), (.cancelled, .uploadCancelled): return true
        default: return false
        }
    }
}

private func mcpBrokerResponse(
    id: Any?,
    response: BrokerResponse,
    expecting expected: ExpectedFileWriteResponse
) throws -> [String: Any] {
    switch response {
    case .success(.fileWrite(let payload)) where expected.matches(payload):
        let encoded = try JSONEncoder().encode(response)
        return mcpToolText(id: id, text: String(decoding: encoded, as: UTF8.self))
    case .failure(let code):
        return try mcpBrokerFailure(id: id, code: code)
    default:
        return try mcpStatusError(id: id, status: "unexpected_response")
    }
}

private func connectionStatus(client: BrokerSocketClient) throws -> String {
    var status: [String: Any]
    do {
        let versionResponse = try client.send(
            .init(version: BrokerProtocolVersion.current, method: "version")
        )
        switch versionResponse {
        case .success(.version(let version)) where version.protocolVersion == BrokerProtocolVersion.current:
            let healthResponse = try client.send(
                .init(version: BrokerProtocolVersion.current, method: "health")
            )
            if case .success(.health(let health)) = healthResponse {
                if health.version != BrokerProtocolVersion.current {
                    status = [
                        "status": "protocol_incompatible",
                        "helperProtocolVersion": BrokerProtocolVersion.current,
                        "brokerProtocolVersion": health.version,
                    ]
                } else if health.status == "ok" {
                    status = [
                        "status": "connected",
                        "helperVersion": helperVersion,
                        "mcpProtocolVersion": mcpProtocolVersion,
                        "brokerProtocolVersion": health.version,
                    ]
                } else {
                    status = ["status": "broker_unavailable"]
                }
            } else if case .failure(.unsupportedVersion) = healthResponse {
                status = [
                    "status": "protocol_incompatible",
                    "helperProtocolVersion": BrokerProtocolVersion.current,
                ]
            } else {
                status = ["status": "broker_unavailable"]
            }
        case .success(.version(let version)):
            status = [
                "status": "protocol_incompatible",
                "helperProtocolVersion": BrokerProtocolVersion.current,
                "brokerProtocolVersion": version.protocolVersion,
            ]
        case .failure(.unsupportedVersion):
            status = [
                "status": "protocol_incompatible",
                "helperProtocolVersion": BrokerProtocolVersion.current,
            ]
        default:
            status = ["status": "broker_unavailable"]
        }
    } catch let error as BrokerSocketError {
        let failure = connectionFailure(for: error)
        status = ["status": failure.status]
        if let brokerCode = failure.brokerCode { status["brokerCode"] = brokerCode }
    } catch {
        status = ["status": "request_failed"]
    }
    let data = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func mcpSuccess(id: Any?, result: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
}

private func mcpFailure(id: Any?, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
}

private func mcpToolText(id: Any?, text: String, guidance: String? = nil) -> [String: Any] {
    var content = [["type": "text", "text": text]]
    if let guidance { content.append(["type": "text", "text": guidance]) }
    return mcpSuccess(id: id, result: ["content": content])
}

private func mcpToolError(id: Any?, message: String) -> [String: Any] {
    mcpSuccess(id: id, result: [
        "content": [["type": "text", "text": message]],
        "isError": true,
    ])
}

private func mcpToolFailure(id: Any?, error: Error) throws -> [String: Any] {
    guard let socketError = error as? BrokerSocketError else {
        return try mcpStatusError(id: id, status: "request_failed")
    }
    let failure = connectionFailure(for: socketError)
    return try mcpStatusError(
        id: id,
        status: failure.status,
        brokerCode: failure.brokerCode
    )
}

private func connectionFailure(for error: BrokerSocketError) -> (status: String, brokerCode: String?) {
    switch error {
    case .notRunning:
        return ("broker_unavailable", nil)
    case .noResponse, .malformedResponse, .systemError:
        return ("broker_disconnected", nil)
    case .brokerFailure(let code):
        return (
            brokerFailureStatus(code),
            code.rawValue
        )
    case .pathTooLong, .frameTooLarge, .responseTooLarge:
        return ("request_failed", nil)
    }
}

private func mcpBrokerFailure(id: Any?, code: BrokerErrorCode) throws -> [String: Any] {
    try mcpStatusError(
        id: id,
        status: brokerFailureStatus(code),
        brokerCode: code.rawValue
    )
}

private func brokerFailureStatus(_ code: BrokerErrorCode) -> String {
    code == .unsupportedVersion ? "protocol_incompatible" : "request_rejected"
}

private func mcpStatusError(
    id: Any?,
    status: String,
    brokerCode: String? = nil
) throws -> [String: Any] {
    var payload = ["status": status]
    if let brokerCode { payload["brokerCode"] = brokerCode }
    if brokerCode == BrokerErrorCode.requestRejected.rawValue {
        payload["next_step"] = AgentUsageGuide.rejected
    }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return mcpToolError(id: id, message: String(decoding: data, as: UTF8.self))
}

private func openHostApplication() throws {
    let helper = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .standardizedFileURL.resolvingSymlinksInPath()
#if DEBUG
    try HelperHostApplication.openHost(helperURL: helper, isDevelopmentBuild: true)
#else
    try HelperHostApplication.openHost(helperURL: helper, isDevelopmentBuild: false)
#endif
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw HelperError.usage }
    if command == "hook" {
        guard arguments.count == 2 else { throw HelperError.usage }
        if arguments[1] == "capabilities" {
            try writeMCPResponse(["protocolVersion": 1, "clients": ["cursor", "grok"]])
            exit(EXIT_SUCCESS)
        }
        guard ["cursor", "grok"].contains(arguments[1]) else { throw HelperError.usage }
        var response = CommandDiscoveryHook.allow(client: arguments[1])
        if case .frame(let data) = readMCPFrame(maximumBytes: BrokerLimits.maximumFrameBytes),
           let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Discovery is a reminder. Invalid input or unavailable ephemeral
            // state cannot authorize a credential or block unrelated work.
            response = (try? CommandDiscoveryHook.response(client: arguments[1], input: input)) ?? response
        }
        try writeMCPResponse(response)
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
