import Foundation
import CoreFoundation
import AskKeyBroker

func mcpTextWriteResponse(id: Any?, response: BrokerResponse) throws -> [String: Any] {
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

func mcpRequestStateResponse(id: Any?, response: BrokerResponse) throws -> [String: Any] {
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

func mcpBrokerResponse(
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

func mcpSuccess(id: Any?, result: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
}

func mcpFailure(id: Any?, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
}

func mcpToolText(id: Any?, text: String, guidance: String? = nil) -> [String: Any] {
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

func mcpToolFailure(id: Any?, error: Error) throws -> [String: Any] {
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

func connectionFailure(for error: BrokerSocketError) -> (status: String, brokerCode: String?) {
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

func mcpBrokerFailure(id: Any?, code: BrokerErrorCode) throws -> [String: Any] {
    try mcpStatusError(
        id: id,
        status: brokerFailureStatus(code),
        brokerCode: code.rawValue
    )
}

private func brokerFailureStatus(_ code: BrokerErrorCode) -> String {
    code == .unsupportedVersion ? "protocol_incompatible" : "request_rejected"
}

func mcpStatusError(
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
