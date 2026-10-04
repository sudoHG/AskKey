import Foundation
import CoreFoundation
import AskKeyBroker

func connectionStatus(client: BrokerSocketClient) throws -> String {
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
                        "helperVersion": AskKeyVersion.current,
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
