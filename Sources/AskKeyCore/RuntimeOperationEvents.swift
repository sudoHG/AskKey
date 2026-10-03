import Foundation

package enum RuntimeOperation: String, Sendable {
    case cli
    case keychain
    case configWrite
    case cursorHelper
}

/// Optional observation of runtime I/O boundaries. Ordinary executables
/// install no consumer; recording and scenario state belong to the consumer.
package enum RuntimeOperationEvents {
    private static let lock = NSLock()
    private static var consumer: (@Sendable (RuntimeOperation) -> Void)?

    package static func install(_ consumer: (@Sendable (RuntimeOperation) -> Void)?) {
        lock.withLock { self.consumer = consumer }
    }

    static func publish(_ operation: RuntimeOperation) {
        lock.withLock { consumer }?(operation)
    }
}
