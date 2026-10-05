import AppKit
import XCTest
@testable import AskKeyAppKit
import AskKeyVault

/// Focus decisions around the Touch ID prompt. Real activation needs the
/// maintainer's Mac; these tests check when the runner yields and restores.
final class ManagementAuthenticationFocusTests: AskKeyAppTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private var activeAnswers: [Bool]

        init(activeAnswers: [Bool]) { self.activeAnswers = activeAnswers }

        var events: [String] { lock.withLock { log } }

        func record(_ event: String) { lock.withLock { log.append(event) } }

        func nextActive() -> Bool {
            lock.withLock {
                log.append("isActive")
                return activeAnswers.isEmpty ? true : activeAnswers.removeFirst()
            }
        }
    }

    private func runner(_ recorder: Recorder) -> ManagementAuthenticationRunner {
        ManagementAuthenticationRunner(
            // Exits at once without a response, like a dismissed prompt.
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            timeout: 1,
            terminationGrace: 0.05,
            focus: .init(
                isActive: { recorder.nextActive() },
                yield: { _ in recorder.record("yield") },
                activate: { recorder.record("activate") },
                retryDelays: [0.01, 0.02]
            )
        )
    }

    private func authenticate(_ runner: ManagementAuthenticationRunner) async {
        _ = await runner.authenticate(presentation: .init(
            reasonKey: CredentialManagementCopy.manageReason,
            language: "en"
        ))
        // Let the main-queue restore and its retries run.
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @MainActor
    func testAppInFrontYieldsToThePromptAndTakesFocusBack() async {
        // In front at the start; another app took focus when the sheet closed;
        // back in front after the first retry.
        let recorder = Recorder(activeAnswers: [true, false, true])
        await authenticate(runner(recorder))

        XCTAssertEqual(recorder.events, ["isActive", "yield", "activate", "isActive", "activate", "isActive"])
        XCTAssertFalse(ManagementAuthenticationRunner.isPromptShowing)
    }

    @MainActor
    func testAppInFrontDoesNotRepeatActivationOnceBackInFront() async {
        let recorder = Recorder(activeAnswers: [true, true, true])
        await authenticate(runner(recorder))

        XCTAssertEqual(recorder.events, ["isActive", "yield", "activate", "isActive", "isActive"])
    }

    @MainActor
    func testApprovalAnsweredFromAnotherAppLeavesFocusAlone() async {
        let recorder = Recorder(activeAnswers: [false])
        await authenticate(runner(recorder))

        XCTAssertEqual(recorder.events, ["isActive"])
        XCTAssertFalse(ManagementAuthenticationRunner.isPromptShowing)
    }

    @MainActor
    func testPromptEndIsAnnouncedForDockReconciliation() async {
        let ended = expectation(forNotification: .managementAuthenticationPromptDidEnd, object: nil)
        await authenticate(runner(Recorder(activeAnswers: [false])))
        await fulfillment(of: [ended], timeout: 1)
    }
}
