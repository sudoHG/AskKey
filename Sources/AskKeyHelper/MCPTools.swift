import Foundation
import CoreFoundation
import AskKeyBroker

func callMCPTool(
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
