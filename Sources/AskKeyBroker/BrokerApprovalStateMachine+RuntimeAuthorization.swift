import Foundation

extension BrokerApprovalStateMachine {
    func withRuntimeAuthorization<T>(id: UUID, _ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let authorization = runtimeAuthorizations[id], authorization.valid,
              !paused, clock() < authorization.expiresAt else {
            throw BrokerProviderError.requestRejected
        }
        // No observer, file IO, or acquisition of the Vault gate while locked.
        return try body()
    }

    func registerRuntimeCleanup(id: UUID, cleanup: @escaping @Sendable () -> Void) throws {
        lock.lock()
        if var authorization = runtimeAuthorizations[id], authorization.valid,
           !paused, clock() < authorization.expiresAt {
            authorization.cleanups.append(cleanup)
            runtimeAuthorizations[id] = authorization
            lock.unlock()
        } else {
            lock.unlock()
            cleanup()
            throw BrokerProviderError.requestRejected
        }
    }

    func releaseRuntimeAuthorization(id: UUID) {
        let cleanups = mutate { runtimeAuthorizations.removeValue(forKey: id)?.cleanups ?? [] }
        cleanups.forEach { $0() }
    }
    func invalidateRuntimeAuthorizationsLocked(credentialID: String? = nil) {
        for id in runtimeAuthorizations.keys {
            guard var authorization = runtimeAuthorizations[id],
                  credentialID == nil || authorization.credentialIDs.contains(credentialID!) else { continue }
            authorization.valid = false
            runtimeAuthorizations[id] = authorization
        }
    }

    func runtimeInvalidationCleanupsLocked(now: Date) -> [@Sendable () -> Void] {
        var cleanups: [@Sendable () -> Void] = []
        for id in runtimeAuthorizations.keys {
            guard var authorization = runtimeAuthorizations[id],
                  !authorization.valid || now >= authorization.expiresAt else { continue }
            authorization.valid = false
            cleanups.append(contentsOf: authorization.cleanups)
            authorization.cleanups.removeAll()
            runtimeAuthorizations[id] = authorization
        }
        return cleanups
    }
}
