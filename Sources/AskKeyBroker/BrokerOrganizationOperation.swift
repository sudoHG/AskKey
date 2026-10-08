import Foundation

public enum BrokerOrganizationOperation: Codable, Equatable, Sendable {
    case move(credential: String, group: String?)
    case createGroup(String)
    case renameGroup(from: String, to: String)
    case deleteGroup(String)

    var isBounded: Bool {
        let names: [String]
        switch self {
        case .move(let credential, let group): names = [credential] + [group].compactMap { $0 }
        case .createGroup(let name), .deleteGroup(let name): names = [name]
        case .renameGroup(let from, let to): names = [from, to]
        }
        return names.allSatisfy { !$0.isEmpty && $0.utf8.count <= BrokerLimits.maximumFieldBytes }
    }
}
