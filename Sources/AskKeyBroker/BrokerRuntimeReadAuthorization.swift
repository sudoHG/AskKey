import Foundation

/// The original approvals consumed by one runtime operation. Its identity and
/// deadline survive terminal-ticket eviction and cannot be renewed by a later
/// allowance. File cleanup belongs to this identity, never to a credential name.
public final class BrokerRuntimeReadAuthorization: @unchecked Sendable {
    public let expiresAt: Date
    private let owner: BrokerApprovalStateMachine
    private let id: UUID

    init(owner: BrokerApprovalStateMachine, id: UUID, expiresAt: Date) {
        self.owner = owner
        self.id = id
        self.expiresAt = expiresAt
    }

    deinit { finish() }

    public func validate() throws {
        try owner.withRuntimeAuthorization(id: id) {}
    }

    /// Call under the Vault spawn gate. Revocation takes the same approval lock
    /// and therefore cannot complete between this check and the actual spawn.
    public func performAuthorizedSpawn<T>(_ spawn: () throws -> T) throws -> T {
        try owner.withRuntimeAuthorization(id: id, spawn)
    }

    /// Registers a specific materialized resource. If invalidation already won,
    /// clean that resource immediately, outside the approval lock, and refuse it.
    public func registerCleanup(_ cleanup: @escaping @Sendable () -> Void) throws {
        try owner.registerRuntimeCleanup(id: id, cleanup: cleanup)
    }

    public func finish() {
        owner.releaseRuntimeAuthorization(id: id)
    }
}
