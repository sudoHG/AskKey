public enum RestrictedProcessCancellation {
    // A nominal value avoids the Swift runtime crash when pushing an optional
    // closure directly into task-local storage in optimized builds.
    private struct Context: Sendable {
        let isCancelled: @Sendable () -> Bool
    }

    @TaskLocal private static var context: Context?

    public static var current: (@Sendable () -> Bool)? {
        context?.isCancelled
    }

    public static func withValue<Result>(
        _ isCancelled: @escaping @Sendable () -> Bool,
        operation: () throws -> Result
    ) rethrows -> Result {
        try $context.withValue(Context(isCancelled: isCancelled), operation: operation)
    }
}
