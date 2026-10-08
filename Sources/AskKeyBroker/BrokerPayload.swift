import Foundation

public enum BrokerPayload: Codable, Equatable, Sendable {
    case health(BrokerHealth)
    case version(BrokerVersion)
    case catalog([BrokerCatalogItem], groups: [String]? = [])
    case requestStatus(BrokerRequestState)
    case textRun(BrokerTextRunResult)
    case fileWrite(BrokerFileWritePayload)
    case textWriteRequest(AgentTextWriteRequestOutcome)
    case textWriteResult(AgentTextWriteResult)
    case organizationWriteResult(operationID: String)
}
