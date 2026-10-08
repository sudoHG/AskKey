import Foundation
import CoreFoundation
import AskKeyBroker

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

let mcpToolDefinitions: [[String: Any]] = componentMCPToolDefinitions() + [
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
    create["usage_instructions"] = ["type": "string", "description": AgentUsageGuide.metadataWrites]
    create["group"] = ["type": "string", "description": "Reuse a matching group or create it on approved commit. Omitted means Ungrouped."]
    var modify = common
    modify["usage_instructions"] = ["type": "string", "description": AgentUsageGuide.metadataWrites + " Omitted means unchanged; empty string clears instructions."]
    modify["group"] = ["type": ["string", "null"], "description": "Omitted means unchanged; null means Ungrouped. Unknown names create groups on approved commit."]
    modify["changes"] = ["type": "array", "minItems": 1, "maxItems": 64,
        "items": ["type": "object", "oneOf": [
            ["properties": ["upsert": component], "required": ["upsert"], "additionalProperties": false],
            ["properties": ["remove": ["type": "string"]], "required": ["remove"], "additionalProperties": false]]]]
    let upload: [String: Any] = ["upload_id": ["type": "string"], "capability": ["type": "string"]]
    var append = upload
    append["offset"] = ["type": "integer"]
    append["chunk_base64"] = ["type": "string"]
    var modifyDefinition = definition("modify_credential", "Atomically change components, usage instructions and/or group; omitted fields are preserved. Repeat exact operation_id and payload with request_id/capability to commit.", modify, ["name", "operation_id"])
    var modifySchema = modifyDefinition["inputSchema"] as! [String: Any]
    modifySchema["anyOf"] = [["required": ["changes"]], ["required": ["usage_instructions"]], ["required": ["group"]]]
    modifyDefinition["inputSchema"] = modifySchema
    return [
        definition("create_credential", "Create a whole credential with text/file components under one frozen approval. Files use operation-bound staged references; never local paths.", create, ["name", "operation_id", "components"]),
        modifyDefinition,
        definition("begin_component_upload", "Begin encrypted staging for a component in one credential operation.",
            ["operation_id": ["type": "string"], "filename": ["type": "string"], "byte_count": ["type": "integer"]], ["operation_id", "filename", "byte_count"]),
        definition("append_component_upload", "Append a bounded base64 chunk to encrypted component staging.", append, ["upload_id", "capability", "offset", "chunk_base64"]),
        definition("freeze_component_upload", "Freeze staged bytes and return a digest-bound reference for create_credential/modify_credential; this does not approve a write.", upload, ["upload_id", "capability"]),
        definition("cancel_component_upload", "Cancel staging and remove its encrypted temporary payload.", upload, ["upload_id", "capability"]),
    ]
}
