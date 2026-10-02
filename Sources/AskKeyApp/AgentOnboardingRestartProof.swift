#if DEBUG
import AppKit
import CryptoKit
import Darwin
import Foundation
import AskKeyCore

enum AgentOnboardingRestartProof {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["ASKKEY_ONBOARDING_RESTART_PROOF"] == "1"
    }

    private static let lock = NSLock()
    private static var checkCalls = 0
    private static var applyCalls = 0
    private static var observedBeforeAdopt = false
    private static var adoptedPendingRecovery = false

    static func prepareObservation() {
        OnboardingBoundaryObserver.install(AgentOnboardingDebugSupport.boundaryRecorder)
        OnboardingBoundaryObserver.beginPageWindow()
        lock.withLock { observedBeforeAdopt = true }
    }

    static func markAdoptedPendingRecovery() {
        lock.withLock { adoptedPendingRecovery = true }
    }

    static func operations() -> AgentOnboardingOperations {
        AgentOnboardingOperations(
            check: { _, _ in
                lock.withLock { checkCalls += 1 }
                throw AgentOnboardingFailure.cancelled
            },
            apply: { _, _, _ in
                lock.withLock { applyCalls += 1 }
                throw AgentOnboardingFailure.cancelled
            },
            authenticate: { .cancelled }
        )
    }

    @MainActor
    static func run(vault: VaultViewModel) async {
        await vault.onboarding.confirm(.multica)
        export(vault: vault)
        NSApp.terminate(nil)
    }

    @MainActor
    private static func export(vault: VaultViewModel) {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["ASKKEY_ONBOARDING_RESTART_OUTPUT_DIR"] else {
            NSLog("AskKey restart proof failed: output directory is missing")
            return
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("AskKey restart proof failed: \(error.localizedDescription)")
            return
        }
        let session = vault.onboarding.session(for: .multica)
        let journal = journalFile()
        let journalInfo = journal.map(describeJournal) ?? ["present": false]
        let observed: Bool
        let adopted: Bool
        let checks: Int
        let applies: Int
        (observed, adopted, checks, applies) = lock.withLock {
            (observedBeforeAdopt, adoptedPendingRecovery, checkCalls, applyCalls)
        }
        let payload: [String: Any] = [
            "pid": Int(getpid()),
            "pass": environment["ASKKEY_ONBOARDING_RESTART_PASS"] ?? "",
            "journalPhase": environment["ASKKEY_ONBOARDING_RESTART_JOURNAL"] ?? "",
            "multicaPhase": session.attempt.phase.rawValue,
            "changeStatus": session.attempt.changeStatus.rawValue,
            "failure": session.attempt.failure.map { String(describing: $0) } ?? "",
            "hasPlan": session.plan != nil,
            "confirmBlocked": session.attempt.phase == .recoveryRequired
                && (session.attempt.changeStatus == .restoreFailed
                    || session.attempt.changeStatus == .remoteUnknown),
            "checkCalls": checks,
            "applyCalls": applies,
            "boundaries": OnboardingBoundaryObserver.snapshot,
            "journal": journalInfo,
            "windowPresent": NSApp.windows.contains { $0.identifier?.rawValue == "settings" },
            "injectedInitialSessions": environment["ASKKEY_ONBOARDING_STUB"] != nil,
            "observerInstalledBeforeAdopt": observed,
            "adoptedPendingRecovery": adopted
        ]
        let file = directory.appendingPathComponent(
            "pass-\(environment["ASKKEY_ONBOARDING_RESTART_PASS"] ?? "unknown").json"
        )
        do {
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                .write(to: file, options: .atomic)
        } catch {
            NSLog("AskKey restart proof could not write export: \(error.localizedDescription)")
        }
    }

    private static func journalFile() -> URL? {
        let file = VaultConfiguration.daemonSocketURL
            .deletingLastPathComponent()
            .appendingPathComponent("client-backups/multica-recovery/pending.json")
        var info = stat()
        guard file.path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        return file
    }

    private static func describeJournal(_ file: URL) -> [String: Any] {
        var info = stat()
        let hashed: String
        let readError: String
        do {
            let data = try Data(contentsOf: file)
            hashed = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            readError = ""
        } catch {
            hashed = ""
            readError = error.localizedDescription
        }
        let mode: String
        if file.path.withCString({ lstat($0, &info) }) == 0 {
            mode = String(info.st_mode & 0o777, radix: 8)
        } else {
            mode = ""
        }
        return [
            "present": true,
            "path": file.path,
            "sha256": hashed,
            "mode": mode,
            "readError": readError
        ]
    }
}
#endif
