import Foundation

public struct Project: Equatable, Hashable, Codable {
    public var id: String
    public var name: String
    public var activeEnvironment: String?
    public var icon: String?
    public var createdAt: Date?

    public init(id: String, name: String, activeEnvironment: String? = nil, icon: String? = nil, createdAt: Date? = nil) {
        self.id = id
        self.name = name
        self.activeEnvironment = activeEnvironment
        self.icon = icon
        self.createdAt = createdAt
    }
}
