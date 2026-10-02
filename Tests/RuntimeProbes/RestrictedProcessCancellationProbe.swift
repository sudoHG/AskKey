import Foundation

@main
struct RestrictedProcessCancellationProbe {
    static func main() async throws {
        try await Task.detached {
            precondition(RestrictedProcessCancellation.current == nil)
            do {
                try RestrictedProcessCancellation.withValue({ false }) {
                    precondition(RestrictedProcessCancellation.current?() == false)
                    defer { precondition(RestrictedProcessCancellation.current?() == false) }
                    try RestrictedProcessCancellation.withValue({ true }) {
                        precondition(RestrictedProcessCancellation.current?() == true)
                        throw CancellationError()
                    }
                }
                fatalError("Cancellation must propagate through the synchronous task-local boundary")
            } catch is CancellationError {
                precondition(RestrictedProcessCancellation.current == nil)
            }
        }.value
        precondition(RestrictedProcessCancellation.current == nil)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let expected = index.isMultiple(of: 2)
                    RestrictedProcessCancellation.withValue({ expected }) {
                        for _ in 0..<100 {
                            precondition(RestrictedProcessCancellation.current?() == expected)
                        }
                    }
                    precondition(RestrictedProcessCancellation.current == nil)
                }
            }
        }
        print("PASS: detached cancellation, nested error cleanup, and concurrent scope isolation")
    }
}
