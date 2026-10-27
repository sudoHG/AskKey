import AppKit
import Darwin

final class ManagementAuthenticationRunner: @unchecked Sendable {
    static let shared = ManagementAuthenticationRunner()

    /// True while a Touch ID prompt process is running. The app ignores the
    /// focus changes it causes, so the Dock icon does not flicker.
    static var isPromptShowing: Bool { promptCount.value > 0 }
    private static let promptCount = PromptCounter()

    private let queue = DispatchQueue(label: "com.sudohg.askkey.authentication")
    private let executableURL: URL?
    private let timeout: TimeInterval
    private let terminationGrace: TimeInterval
    private let cancellationGrace: TimeInterval
    private let focus: ManagementAuthenticationFocus

    init(
        executableURL: URL? = nil,
        timeout: TimeInterval = 5 * 60,
        terminationGrace: TimeInterval = 0.2,
        cancellationGrace: TimeInterval = 0.5,
        focus: ManagementAuthenticationFocus = .application
    ) {
        self.executableURL = executableURL
        self.focus = focus
        self.timeout = timeout > 0 ? timeout : 5 * 60
        self.terminationGrace = terminationGrace >= 0 ? terminationGrace : 0.2
        self.cancellationGrace = max(0, cancellationGrace)
    }

    func authenticate(
        presentation: ManagementAuthenticationPresentation,
        cancellation: ManagementAuthenticationCancellation = .init()
    ) async -> ManagementAuthenticationOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let completion = AuthenticationCompletion(continuation)
                let observer = cancellation.observe { completion.finish(.cancelled) }
                queue.async {
                    let result = self.run(presentation: presentation, cancellation: cancellation)
                    cancellation.removeObserver(observer)
                    completion.finish(result)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func authenticateBlocking(
        presentation: ManagementAuthenticationPresentation
    ) -> Bool {
        let attempt = ApprovalAuthenticationAttempt.current
        let outcome = outcomeBlocking(
            presentation: presentation, cancellation: attempt?.cancellation ?? .init()
        )
        return attempt?.record(outcome) ?? (outcome == .authenticated)
    }

    func outcomeBlocking(
        presentation: ManagementAuthenticationPresentation,
        cancellation: ManagementAuthenticationCancellation = .init()
    ) -> ManagementAuthenticationOutcome {
        guard !Thread.isMainThread else { return .failed }
        guard !cancellation.isCancelled else { return .cancelled }
        let completion = BlockingAuthenticationCompletion()
        queue.async {
            completion.finish(self.run(presentation: presentation, cancellation: cancellation))
        }
        while completion.ready.wait(timeout: .now() + 0.01) == .timedOut {
            if cancellation.isCancelled { return .cancelled }
        }
        return cancellation.isCancelled ? .cancelled : completion.outcome
    }

    private func run(
        presentation: ManagementAuthenticationPresentation,
        cancellation: ManagementAuthenticationCancellation
    ) -> ManagementAuthenticationOutcome {
        guard !cancellation.isCancelled else { return .cancelled }
        guard let executable = executableURL ?? Bundle.main.executableURL else { return .failed }
        guard ManagementAuthenticationSubprocess.payloadIsWithinLimit(
            presentation: presentation
        ) else { return .failed }
        let process = Process()
        let wasActive = ActivationFlag()
        Self.promptCount.increment()
        // Return focus to the app only when the prompt took it from the app,
        // not when an approval was answered from another app. The Touch ID
        // sheet belongs to the system (coreautha); see ManagementAuthenticationFocus.
        let focus = self.focus
        defer {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Self.promptCount.decrement()
                    NotificationCenter.default.post(name: .managementAuthenticationPromptDidEnd, object: nil)
                    guard wasActive.isSet else { return }
                    focus.activate()
                    // The system may hand focus to the next app only after the
                    // sheet finishes closing; ask again if that happened.
                    for delay in focus.retryDelays {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            MainActor.assumeIsolated {
                                if !focus.isActive() { focus.activate() }
                            }
                        }
                    }
                }
            }
        }
        process.executableURL = executable
        process.arguments = ManagementAuthenticationSubprocess.arguments(
            language: presentation.language,
            describeOnly: false
        )
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard Self.suppressSIGPIPE(
            fileDescriptor: input.fileHandleForWriting.fileDescriptor
        ) else { return .failed }
        var payloadData = ManagementAuthenticationSubprocess.payloadData(
            presentation: presentation
        )
        payloadData.append(0x0a)
        defer { try? input.fileHandleForWriting.close() }
        defer { payloadData.resetBytes(in: payloadData.startIndex..<payloadData.endIndex) }
        do {
            try process.run()
            let pid = process.processIdentifier
            // Record focus and yield it before the prompt process receives its
            // payload, so it cannot activate first. Bounded in case the main
            // thread is busy.
            let handedOver = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    defer { handedOver.signal() }
                    guard focus.isActive() else { return }
                    wasActive.set()
                    focus.yield(pid)
                }
            }
            _ = handedOver.wait(timeout: .now() + 2)
            try input.fileHandleForWriting.write(contentsOf: payloadData)
        } catch {
            try? input.fileHandleForWriting.close()
            stop(process, input: input)
            return cancellation.isCancelled ? .cancelled : .failed
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline, !cancellation.isCancelled {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if cancellation.isCancelled {
            stop(process, input: input)
            return .cancelled
        }
        if process.isRunning {
            stop(process, input: input)
            return .failed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let response = try? JSONDecoder().decode(
                ManagementAuthenticationResponse.self,
                from: output.fileHandleForReading.readDataToEndOfFile()
              ) else {
            return .failed
        }
        return cancellation.isCancelled ? .cancelled : response.outcome
    }

    private func waitWhileRunning(_ process: Process, until deadline: Date) {
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func stop(_ process: Process, input: Pipe) {
        guard process.isRunning else { return }
        // Let the child invalidate LAContext, yield focus and exit normally.
        try? input.fileHandleForWriting.write(contentsOf: Data("cancel\n".utf8))
        try? input.fileHandleForWriting.close()
        waitWhileRunning(process, until: Date().addingTimeInterval(cancellationGrace))
        guard process.isRunning else { process.waitUntilExit(); return }
        process.terminate()
        waitWhileRunning(process, until: Date().addingTimeInterval(terminationGrace))
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            waitWhileRunning(process, until: Date().addingTimeInterval(terminationGrace))
        }
    }

    static func suppressSIGPIPE(fileDescriptor: Int32) -> Bool {
        fcntl(fileDescriptor, F_SETNOSIGPIPE, 1) == 0
    }
}

private final class AuthenticationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ManagementAuthenticationOutcome, Never>?

    init(_ continuation: CheckedContinuation<ManagementAuthenticationOutcome, Never>) {
        self.continuation = continuation
    }

    func finish(_ outcome: ManagementAuthenticationOutcome) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: outcome)
    }
}

private final class BlockingAuthenticationCompletion: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: ManagementAuthenticationOutcome = .failed
    var outcome: ManagementAuthenticationOutcome { lock.withLock { result } }

    func finish(_ outcome: ManagementAuthenticationOutcome) {
        lock.withLock { result = outcome }
        ready.signal()
    }
}

/// Records, from the main thread, whether the app was active when the
/// authentication prompt started.
private final class ActivationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}

/// How the runner hands focus to the Touch ID prompt and takes it back.
/// Injected so tests can check these decisions without a real application.
struct ManagementAuthenticationFocus: Sendable {
    var isActive: @MainActor @Sendable () -> Bool
    var yield: @MainActor @Sendable (pid_t) -> Void
    /// Must ignore other apps: when the system sheet closes, macOS has already
    /// activated the next app and refuses a cooperative request.
    var activate: @MainActor @Sendable () -> Void
    var retryDelays: [TimeInterval]

    // NSApp is nil when the runner is exercised without an application.
    static let application = ManagementAuthenticationFocus(
        isActive: { (NSApp as NSApplication?)?.isActive ?? false },
        yield: { pid in
            guard let app = NSApp as NSApplication?,
                  let prompt = NSRunningApplication(processIdentifier: pid) else { return }
            app.yieldActivation(to: prompt)
        },
        activate: { (NSApp as NSApplication?)?.activate(ignoringOtherApps: true) },
        retryDelays: [0.25, 0.75]
    )
}

/// Counts running Touch ID prompts; incremented on the worker queue and
/// decremented on the main queue, so overlapping prompts never clear each other.
private final class PromptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }

    func decrement() { lock.withLock { count = max(0, count - 1) } }
}

extension Notification.Name {
    static let managementAuthenticationPromptDidEnd = Notification.Name("ManagementAuthenticationPromptDidEnd")
}
