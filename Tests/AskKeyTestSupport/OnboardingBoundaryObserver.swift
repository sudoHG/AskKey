import Foundation
import AskKeySystem

/// Test-owned recording of the runtime boundaries observed during a scenario.
package enum OnboardingBoundaryObserver {
    package typealias Kind = RuntimeOperation

    @TaskLocal package static var active = false

    private static let windowLock = NSLock()
    private static var pageWindow = false

    package static func beginPageWindow() {
        windowLock.withLock { pageWindow = true }
    }

    package static func endPageWindow() {
        windowLock.withLock { pageWindow = false }
    }

    package static var isPageWindowActive: Bool {
        windowLock.withLock { pageWindow }
    }

    package static let emptySnapshot: [String: Int] = [
        "cli": 0, "keychain": 0, "configWrite": 0, "cursorHelper": 0
    ]

    package final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Kind: Int] = [:]

        package init() {}

        package func add(_ kind: Kind) {
            lock.withLock { counts[kind, default: 0] += 1 }
        }

        package func count(_ kind: Kind) -> Int {
            lock.withLock { counts[kind, default: 0] }
        }

        package var snapshot: [String: Int] {
            lock.withLock {
                [
                    "cli": counts[.cli, default: 0],
                    "keychain": counts[.keychain, default: 0],
                    "configWrite": counts[.configWrite, default: 0],
                    "cursorHelper": counts[.cursorHelper, default: 0]
                ]
            }
        }

        package func reset() {
            lock.withLock { counts = [:] }
        }
    }

    private static let lock = NSLock()
    private static var installed: Recorder?

    package static func install(_ recorder: Recorder?) {
        lock.withLock { installed = recorder }
        if recorder == nil {
            RuntimeOperationEvents.install(nil)
        } else {
            RuntimeOperationEvents.install { operation in note(operation) }
        }
    }

    private static func note(_ kind: Kind) {
        guard active || isPageWindowActive else { return }
        lock.withLock { installed }?.add(kind)
    }

    package static func count(_ kind: Kind) -> Int {
        lock.withLock { installed?.count(kind) ?? 0 }
    }

    package static var snapshot: [String: Int] {
        lock.withLock { installed?.snapshot ?? emptySnapshot }
    }

}
