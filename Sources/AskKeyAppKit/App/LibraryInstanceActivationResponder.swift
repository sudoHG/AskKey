import Foundation

/// Acknowledgement does not depend on window creation or the main actor.
final class LibraryInstanceActivationResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var ownsLibrary = false

    func acquire(in directory: URL) throws -> LibraryInstanceLock? {
        lock.lock(); defer { lock.unlock() }
        let owner = try LibraryInstanceLock.acquire(in: directory)
        ownsLibrary = owner != nil
        return owner
    }

    @discardableResult
    func acknowledge(_ request: String, reply: () -> Void) -> Bool {
        lock.lock()
        let owned = ownsLibrary
        lock.unlock()
        guard owned, UUID(uuidString: request) != nil else { return false }
        reply()
        return true
    }
}
