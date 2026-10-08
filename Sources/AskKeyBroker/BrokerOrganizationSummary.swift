import Foundation

/// App-only, value-free presentation of the exact ordered frozen batch.
public struct BrokerOrganizationSummary: Codable, Equatable, Sendable {
    public enum Operation: Codable, Equatable, Sendable {
        case move(credential: String, from: String?, to: String?)
        case createGroup(String)
        case existingGroup(name: String, members: Int, nonvisible: Int)
        case renameGroup(from: String, to: String, members: Int, nonvisible: Int)
        case mergeGroup(from: String, to: String, members: Int, nonvisible: Int, targetMembers: Int, targetNonvisible: Int)
        case deleteGroup(name: String, members: Int, nonvisible: Int)
    }

    public let operations: [Operation]

    public init(operations: [Operation]) { self.operations = operations }
}
