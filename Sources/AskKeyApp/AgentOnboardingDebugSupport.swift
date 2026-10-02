#if DEBUG
import AppKit
import AskKeyCore
import CoreGraphics
import Foundation
import SwiftUI

enum DebugPressRegistry {
    private static var actions: [String: () -> Void] = [:]

    static func register(_ identifier: String, _ action: @escaping () -> Void) {
        actions[identifier] = action
    }

    static func remove(_ identifier: String) {
        // Keep the latest action. SwiftUI re-renders can fire onDisappear
        // while the control is still on screen.
        _ = identifier
    }

    static func press(_ identifier: String) -> Bool {
        guard let action = actions[identifier] else { return false }
        action()
        return true
    }

    static var identifiers: [String] {
        actions.keys.sorted()
    }
}

struct DebugPressAnchor: View {
    let identifier: String
    let action: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityHidden(true)
            .onAppear { DebugPressRegistry.register(identifier, action) }
            .onDisappear { DebugPressRegistry.remove(identifier) }
    }
}

extension View {
    func debugPress(_ identifier: String, action: @escaping () -> Void) -> some View {
        onAppear { DebugPressRegistry.register(identifier, action) }
            .onDisappear { DebugPressRegistry.remove(identifier) }
    }
}

/// Wiring-test hook only. B2 real-UI evidence must use `RealUIInput`, not this.
enum DebugAccessibility {
    @discardableResult
    static func press(identifier: String, in view: NSView) -> Bool {
        if DebugPressRegistry.press(identifier) { return true }
        if pressObject(identifier, view) { return true }
        for subview in view.subviews {
            if pressObject(identifier, subview) { return true }
            if press(identifier: identifier, in: subview) { return true }
        }
        for window in NSApp.windows {
            if let content = window.contentView, content !== view,
               pressObject(identifier, content) {
                return true
            }
        }
        return DebugPressRegistry.press(identifier)
    }

    private static func pressObject(_ identifier: String, _ object: NSObject) -> Bool {
        if elementID(object) == identifier {
            if performPress(object) { return true }
            if let button = object as? NSButton {
                button.performClick(nil)
                return true
            }
        }
        for child in children(of: object) {
            if pressObject(identifier, child) { return true }
        }
        return false
    }

    private static func elementID(_ object: NSObject) -> String? {
        if let view = object as? NSView {
            let identifier = view.accessibilityIdentifier()
            if !identifier.isEmpty { return identifier }
            return view.identifier?.rawValue
        }
        if let element = object as? NSAccessibilityElement,
           let identifier = element.accessibilityIdentifier(),
           !identifier.isEmpty {
            return identifier
        }
        return object.value(forKey: "accessibilityIdentifier") as? String
    }

    private static func performPress(_ object: NSObject) -> Bool {
        if let view = object as? NSView {
            return view.accessibilityPerformPress()
        }
        if let element = object as? NSAccessibilityElement {
            return element.accessibilityPerformPress()
        }
        return false
    }

    private static func children(of object: NSObject) -> [NSObject] {
        if let view = object as? NSView, let children = view.accessibilityChildren() as? [NSObject] {
            return children
        }
        if let element = object as? NSAccessibilityElement,
           let children = element.accessibilityChildren() as? [NSObject] {
            return children
        }
        return []
    }
}

enum AgentOnboardingDebugSupport {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["ASKKEY_ONBOARDING_PROOF"] == "1"
    }

    static func operationsIfRequested() -> AgentOnboardingOperations? {
        guard isRequested || ProcessInfo.processInfo.environment["ASKKEY_ONBOARDING_STUB"] != nil else {
            return nil
        }
        return counters.operations(scenario: StubScenario.current)
    }

    static let counters = OnboardingSideEffectCounters()
    static let boundaryRecorder = OnboardingBoundaryObserver.Recorder()

    static func installBoundaryRecorder() {
        OnboardingBoundaryObserver.install(boundaryRecorder)
    }

    static func runIsolatedBoundaryPositiveControl() throws {
        OnboardingBoundaryObserver.beginPageWindow()
        try OnboardingBoundaryObserver.probeIsolatedCLI()
        OnboardingBoundaryObserver.probeRejectedKeychain()
        try OnboardingBoundaryObserver.probeIsolatedConfigWrite()
        try OnboardingBoundaryObserver.probeCursorHelperLaunch()
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/usr/bin/true"),
            helperIsTrusted: { _ in true },
            command: ProcessMulticaWorkspaceMCPCommand.make(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                addTimeout: 1
            )
        )
        _ = try? adapter.checkStatus()
    }

    enum StubScenario: String {
        case idle
        case network
        case plan
        case success
        case remoteUnknown = "remote-unknown"
        case restoreFailed = "restore-failed"
        case hang

        static var current: Self {
            Self(rawValue: ProcessInfo.processInfo.environment["ASKKEY_ONBOARDING_STUB"] ?? "idle")
            ?? .idle
        }
    }
}

final class OnboardingSideEffectCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var check = 0
    private var apply = 0

    var snapshot: [String: Int] {
        lock.withLock {
            [
                "check": check,
                "apply": apply,
                "cli": OnboardingBoundaryObserver.count(.cli),
                "multicaCLI": OnboardingBoundaryObserver.count(.multicaCLI),
                "keychain": OnboardingBoundaryObserver.count(.keychain),
                "configWrite": OnboardingBoundaryObserver.count(.configWrite),
                "cursorHelper": OnboardingBoundaryObserver.count(.cursorHelper)
            ]
        }
    }

    func operations(scenario: AgentOnboardingDebugSupport.StubScenario) -> AgentOnboardingOperations {
        AgentOnboardingOperations(
            check: { client, cancellation in
                self.lock.withLock { self.check += 1 }
                if scenario == .hang {
                    for _ in 0..<400 {
                        if cancellation.isCancelled { throw AgentOnboardingFailure.cancelled }
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    throw AgentOnboardingFailure.timedOut
                }
                return self.checkReport(client: client, scenario: scenario)
            },
            apply: { client, _, _ in
                self.lock.withLock { self.apply += 1 }
                return self.applyReport(client: client, scenario: scenario)
            },
            authenticate: { .confirmed }
        )
    }

    private func checkReport(
        client: AgentClient,
        scenario: AgentOnboardingDebugSupport.StubScenario
    ) -> AgentCheckReport {
        switch scenario {
        case .network:
            return AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: client.rawValue,
                plan: nil,
                failure: .networkUnavailable
            )
        case .plan, .success, .remoteUnknown, .restoreFailed:
            return AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: client.rawValue,
                plan: Self.plan(for: client),
                failure: nil
            )
        case .idle, .hang:
            return AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: client.rawValue,
                plan: nil,
                failure: nil
            )
        }
    }

    private func applyReport(
        client: AgentClient,
        scenario: AgentOnboardingDebugSupport.StubScenario
    ) -> AgentApplyReport {
        switch scenario {
        case .success:
            let discovery: CredentialDiscoveryReadiness? = switch client {
            case .codex: .enabled
            case .cursor, .grok: .configured
            case .multica: nil
            }
            return AgentApplyReport(
                outcome: client == .multica ? .workspaceConfigured : .verifiedConnected,
                changeStatus: .verifiedAndKept,
                failure: nil,
                targetSummary: client.rawValue,
                discovery: discovery
            )
        case .remoteUnknown:
            return AgentApplyReport(
                outcome: .configuredUnverified,
                changeStatus: .remoteUnknown,
                failure: .remoteUnknown,
                targetSummary: client.rawValue
            )
        case .restoreFailed:
            return AgentApplyReport(
                outcome: .notConfigured,
                changeStatus: .restoreFailed,
                failure: .restoreFailed,
                targetSummary: client.rawValue
            )
        default:
            return AgentApplyReport(
                outcome: .notConfigured,
                changeStatus: .notWritten,
                failure: .cancelled,
                targetSummary: client.rawValue
            )
        }
    }

    private static func plan(for client: AgentClient) -> AgentOnboardingPlan {
        AgentOnboardingPlan(
            client: client,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            targetIdentity: client.rawValue,
            scopeSummary: client == .multica
                ? "Workspace Studio · 2 agents"
                : "Add Ask Key for the current user of \(client.rawValue).",
            agentIDs: client == .multica ? ["agent-1", "agent-2"] : [],
            agentNames: client == .multica ? ["Writer", "Reviewer"] : [],
            workspaceID: client == .multica ? "ws-1" : nil,
            workspaceName: client == .multica ? "Studio" : nil,
            serverID: nil,
            createsServer: client == .multica,
            configurationPresent: false,
            verifiesOnly: false,
            preconditionSummary: "If verification fails, Ask Key restores the original settings.",
            activeAgentFingerprint: client == .multica ? "agent-1,agent-2" : ""
        )
    }
}

@MainActor
enum AgentOnboardingDebugDriver {
    static func run(window: NSWindow, vault: VaultViewModel) async {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["ASKKEY_ONBOARDING_PROOF_OUTPUT_DIR"] else {
            NSLog("AskKey onboarding proof failed: output directory is missing")
            NSApp.terminate(nil)
            return
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("AskKey onboarding proof failed: \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }
        let logURL = directory.appendingPathComponent("actions.md")
        var log = ["# \(environment["ASKKEY_ONBOARDING_PROOF_SCENARIO"] ?? "unknown")", ""]
        func record(_ line: String) {
            log.append(line)
        }

        if !vault.hasManagementSession {
            record("- unlock: request management session via DEBUG stand-in")
            await vault.unlockForManagement()
        }
        await pause(600)
        AgentOnboardingDebugSupport.installBoundaryRecorder()
        record("- input-policy: real visible control via mouse-nsevent or system AX; DebugPressRegistry is not used")
        record("- start: hasManagementSession=\(vault.hasManagementSession) locked=\(vault.isLocked) error=\(vault.errorMessage ?? "nil")")
        for line in RealUIInput.describeTree() {
            record(line)
        }

        let scenario = environment["ASKKEY_ONBOARDING_PROOF_SCENARIO"] ?? "first-visit"
        await play(scenario, window: window, vault: vault, directory: directory, record: record)

        let counts = AgentOnboardingDebugSupport.counters.snapshot
        record("- counts: \(counts)")
        do {
            try log.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
            try JSONSerialization.data(withJSONObject: counts, options: [.prettyPrinted])
                .write(to: directory.appendingPathComponent("counts.json"), options: .atomic)
        } catch {
            NSLog("AskKey onboarding proof could not write log: \(error.localizedDescription)")
        }
        NSApp.terminate(nil)
    }

    private static func play(
        _ scenario: String,
        window: NSWindow,
        vault: VaultViewModel,
        directory: URL,
        record: (String) -> Void
    ) async {
        guard let view = window.contentView else {
            record("- FAIL: management window has no content view")
            return
        }
        window.makeKeyAndOrderFront(nil)
        await pause(400)

        switch scenario {
        case "a01-cycles":
            await runA01(window: window, view: view, vault: vault, directory: directory, record: record)
        case "first-visit":
            await enterAgentPage(window: window, vault: vault, record: record)
            record("- expected: four clients show not checked; no check started")
            record("- actual: check-phase idle, lastKnown=\(vault.onboarding.session(for: .multica).lastKnownResult?.outcome.rawValue ?? "nil")")
            capture(view, to: directory.appendingPathComponent("shot.png"), record: record)
        case "network-error":
            await enterAgentPage(window: window, vault: vault, record: record)
            await click("onboarding-review-multica", window: window, vault: vault, record: record)
            record("- after review: expanded=\(String(describing: vault.onboarding.expandedClient))")
            await click("onboarding-check-multica", window: window, vault: vault, record: record)
            await pause(250)
            record("- expected: Multica row shows temporary reach error; no global alert")
            record("- actual: failure=\(String(describing: vault.onboarding.session(for: .multica).attempt.failure)) errorMessage=\(vault.errorMessage ?? "nil")")
            capture(view, to: directory.appendingPathComponent("shot.png"), record: record)
        case "ready-to-confirm":
            await enterAgentPage(window: window, vault: vault, record: record)
            await click("onboarding-review-codex", window: window, vault: vault, record: record)
            await click("onboarding-check-codex", window: window, vault: vault, record: record)
            await pause(250)
            record("- expected: Codex ready to confirm with scope text")
            record("- actual: phase=\(vault.onboarding.session(for: .codex).attempt.phase.rawValue) plan=\(vault.onboarding.session(for: .codex).plan != nil)")
            capture(view, to: directory.appendingPathComponent("shot.png"), record: record)
        case "success":
            await enterAgentPage(window: window, vault: vault, record: record)
            await click("onboarding-review-codex", window: window, vault: vault, record: record)
            await click("onboarding-check-codex", window: window, vault: vault, record: record)
            await pause(250)
            await click("onboarding-confirm-codex", window: window, vault: vault, record: record)
            await pause(250)
            record("- expected: verified connection after confirm")
            record("- actual: outcome=\(vault.onboarding.session(for: .codex).lastKnownResult?.outcome.rawValue ?? "nil") change=\(vault.onboarding.session(for: .codex).attempt.changeStatus.rawValue)")
            capture(view, to: directory.appendingPathComponent("shot.png"), record: record)
        case "remote-unknown":
            await enterAgentPage(window: window, vault: vault, record: record)
            await click("onboarding-review-multica", window: window, vault: vault, record: record)
            await click("onboarding-check-multica", window: window, vault: vault, record: record)
            await pause(250)
            await click("onboarding-confirm-multica", window: window, vault: vault, record: record)
            await pause(250)
            record("- expected: remote unknown, ordinary write blocked")
            record("- actual: phase=\(vault.onboarding.session(for: .multica).attempt.phase.rawValue) failure=\(String(describing: vault.onboarding.session(for: .multica).attempt.failure))")
            capture(view, to: directory.appendingPathComponent("shot.png"), record: record)
        case "restore-failed":
            await enterAgentPage(window: window, vault: vault, record: record)
            await click("onboarding-review-cursor", window: window, vault: vault, record: record)
            await click("onboarding-check-cursor", window: window, vault: vault, record: record)
            await pause(250)
            await click("onboarding-confirm-cursor", window: window, vault: vault, record: record)
            await pause(250)
            record("- expected: restore failed, ordinary retry blocked")
            record("- actual: phase=\(vault.onboarding.session(for: .cursor).attempt.phase.rawValue) change=\(vault.onboarding.session(for: .cursor).attempt.changeStatus.rawValue)")
            capture(view, to: directory.appendingPathComponent("shot.png"), record: record)
        case "keyboard-check":
            await enterAgentPage(window: window, vault: vault, record: record)
            await click("onboarding-review-codex", window: window, vault: vault, record: record)
            await pause(150)
            record("- keyboard: Tab then Space/Return only after AX focus; no press/Registry/forced-focus fallback")
            await activateByKeyboard(
                identifier: "onboarding-check-codex",
                window: window,
                vault: vault,
                record: record
            )
            await pause(250)
            record("- actual after keyboard check: phase=\(vault.onboarding.session(for: .codex).attempt.phase.rawValue) checks=\(AgentOnboardingDebugSupport.counters.snapshot["check"] ?? 0)")
            capture(view, to: directory.appendingPathComponent("shot.png"), record: record)
        case "focusable-contrast":
            await runFocusableContrast(from: window, record: record)
        case "focus-handoff":
            await runFocusHandoffContrast(from: window, record: record)
        case "keyboard-cancel":
            await enterAgentPage(window: window, vault: vault, record: record)
            await click("onboarding-review-multica", window: window, vault: vault, record: record)
            await pause(150)
            record("- cancel-path: start check by keyboard only; no AX press on check or cancel")
            await activateByKeyboard(
                identifier: "onboarding-check-multica",
                window: window,
                vault: vault,
                record: record
            )
            var appeared = false
            for _ in 0..<40 {
                let session = vault.onboarding.session(for: .multica)
                if session.attempt.phase == .checking,
                   RealUIInput.find(identifier: "onboarding-cancel-multica") != nil {
                    appeared = true
                    break
                }
                await pause(50)
            }
            let handoff = RealUIInput.observeFocus(
                window: window,
                targetIdentifier: "onboarding-cancel-multica"
            )
            record("- after keyboard-started check: appeared=\(appeared) phase=\(vault.onboarding.session(for: .multica).attempt.phase.rawValue) \(handoff.line(step: -1))")
            record("- cancel-path: Tab then Space/Return only after AX focus; no press/Registry/forced-focus fallback")
            await activateByKeyboard(
                identifier: "onboarding-cancel-multica",
                window: window,
                vault: vault,
                record: record
            )
            await pause(250)
            record("- actual after keyboard cancel: phase=\(vault.onboarding.session(for: .multica).attempt.phase.rawValue) failure=\(String(describing: vault.onboarding.session(for: .multica).attempt.failure))")
            capture(view, to: directory.appendingPathComponent("shot.png"), record: record)
        default:
            record("- FAIL: unknown scenario \(scenario)")
        }
    }

    private static func runA01(
        window: NSWindow,
        view: NSView,
        vault: VaultViewModel,
        directory: URL,
        record: (String) -> Void
    ) async {
        record("- A01: enter/exit Agent access 10 times, expand four clients, do not check")
        record("- observe: page window stays open; zeros are not from turning the observer off")
        AgentOnboardingDebugSupport.installBoundaryRecorder()
        AgentOnboardingDebugSupport.boundaryRecorder.reset()
        OnboardingBoundaryObserver.beginPageWindow()
        do {
            try AgentOnboardingDebugSupport.runIsolatedBoundaryPositiveControl()
            let positive = AgentOnboardingDebugSupport.counters.snapshot
            record("- positive-control layer=View-outside page window, bypass boundOperations")
            record("- cursorHelper via CursorUserMCPAdapter.probeMCP Foundation Process, not a hand-written note")
            record("- positive-control expected: cli/multicaCLI/keychain/configWrite/cursorHelper each > 0")
            record("- positive-control actual: \(positive)")
            if (positive["cli"] ?? 0) == 0 || (positive["multicaCLI"] ?? 0) == 0
                || (positive["keychain"] ?? 0) == 0 || (positive["configWrite"] ?? 0) == 0
                || (positive["cursorHelper"] ?? 0) == 0 {
                record("- FAIL: positive-control apparatus did not increment all observed boundaries")
            }
        } catch {
            record("- FAIL: positive-control \(error.localizedDescription)")
        }
        AgentOnboardingDebugSupport.boundaryRecorder.reset()
        record("- page-window-still-active=\(OnboardingBoundaryObserver.isPageWindowActive)")
        for index in 1...10 {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await pause(250)
            await enterAgentPage(window: window, vault: vault, record: record)
            for client in AgentClient.allCases {
                await click("onboarding-review-\(client.proofID)", window: window, vault: vault, record: record)
            }
            await click("sidebar-settings", window: window, vault: vault, record: record)
            record("- sidebar exit cycle \(index) route=\(String(describing: vault.onboarding.expandedClient))")
            await pause(150)
        }
        let counts = AgentOnboardingDebugSupport.counters.snapshot
        record("- expected: check/apply/cli/multicaCLI/keychain/configWrite/cursorHelper all 0; observer still on")
        record("- page-window-still-active=\(OnboardingBoundaryObserver.isPageWindowActive)")
        record("- actual: \(counts)")
        capture(view, to: directory.appendingPathComponent("shot.png"), record: record)
    }

    private static func enterAgentPage(
        window: NSWindow,
        vault: VaultViewModel,
        record: (String) -> Void
    ) async {
        record("- before sidebar-agent expanded=\(String(describing: vault.onboarding.expandedClient))")
        await click("sidebar-agent", window: window, vault: vault, record: record)
        await pause(450)
    }

    private static func click(
        _ identifier: String,
        window: NSWindow,
        vault: VaultViewModel?,
        record: (String) -> Void
    ) async {
        let before = activationSnapshot(identifier, vault: vault)
        for attempt in 1...3 {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if attempt > 1 {
                record("- retry \(attempt) \(identifier) after raising key window")
                await pause(200)
            }
            let hit = RealUIInput.clickVisible(identifier: identifier, window: window, record: record)
            await pause(220)
            if hit.method != "none", activationChanged(identifier, before: before, vault: vault) {
                record("- confirmed \(identifier) after \(hit.method)")
                return
            }
            if hit.method != "none" {
                record("- \(hit.method) did not change \(identifier) state; trying system AX press")
                _ = RealUIInput.systemAXPress(identifier: identifier, record: record)
                await pause(220)
                if activationChanged(identifier, before: before, vault: vault) {
                    record("- confirmed \(identifier) after ax-system-press")
                    return
                }
            }
        }
        record("- FAIL: \(identifier) visible-control activation did not change state; no Registry fallback")
    }

    private static func activationSnapshot(_ identifier: String, vault: VaultViewModel?) -> String {
        if identifier == "sidebar-agent" {
            return RealUIInput.find(identifier: "onboarding-review-codex") == nil ? "page-absent" : "page-present"
        }
        if identifier == "sidebar-settings" || identifier == "sidebar-records" {
            return RealUIInput.find(identifier: "onboarding-review-codex") == nil ? "page-absent" : "page-present"
        }
        if identifier.hasPrefix("onboarding-review-"), let vault {
            return String(describing: vault.onboarding.expandedClient)
        }
        if identifier.hasPrefix("onboarding-check-") {
            return "check=\(AgentOnboardingDebugSupport.counters.snapshot["check"] ?? 0)"
        }
        if identifier.hasPrefix("onboarding-confirm-") {
            return "apply=\(AgentOnboardingDebugSupport.counters.snapshot["apply"] ?? 0)"
        }
        if identifier.hasPrefix("onboarding-cancel-"), let vault {
            let session = vault.onboarding.session(for: .multica)
            return "phase=\(session.attempt.phase.rawValue) failure=\(String(describing: session.attempt.failure))"
        }
        return "unknown"
    }

    private static func activationChanged(
        _ identifier: String,
        before: String,
        vault: VaultViewModel?
    ) -> Bool {
        activationSnapshot(identifier, vault: vault) != before
    }

    private static func keyboardActionSucceeded(
        identifier: String,
        vault: VaultViewModel
    ) -> Bool {
        if identifier.hasPrefix("onboarding-check-") {
            return (AgentOnboardingDebugSupport.counters.snapshot["check"] ?? 0) > 0
        }
        if identifier.hasPrefix("onboarding-cancel-") {
            let session = vault.onboarding.session(for: .multica)
            return session.attempt.failure == nil
                && (session.attempt.phase == .explanation || session.attempt.phase == .readyToConfirm)
        }
        return false
    }

    private static func runFocusableContrast(
        from host: NSWindow,
        record: (String) -> Void
    ) async {
        let taps = ContrastTaps()
        let focusable = await runContrastPanel(
            title: "focusable",
            identifier: "focusable-button",
            style: .plainFocusable,
            host: host,
            taps: taps,
            record: record
        ) { taps.focusable }
        let activate = await runContrastPanel(
            title: "activate",
            identifier: "activate-button",
            style: .activateFocusable,
            host: host,
            taps: taps,
            record: record
        ) { taps.activate }
        let native = await runContrastPanel(
            title: "native",
            identifier: "native-button",
            style: .native,
            host: host,
            taps: taps,
            record: record
        ) { taps.native }
        record("- contrast focusable taps=\(taps.focusable) activated=\(focusable)")
        record("- contrast activate taps=\(taps.activate) activated=\(activate)")
        record("- contrast native taps=\(taps.native) activated=\(native)")
        if focusable == false && activate == true {
            record("- contrast RED: bare .focusable() blocked Space; .focusable(interactions: .activate) activated")
        } else if focusable == false && native == true {
            record("- contrast RED: .focusable() blocked Space; native Button activated")
        } else if focusable == false {
            record("- contrast RED: bare .focusable() took AX focus and blocked Space")
        }
        host.makeKeyAndOrderFront(nil)
    }

    private static func runFocusHandoffContrast(
        from host: NSWindow,
        record: (String) -> Void
    ) async {
        let swap = await runHandoffPanel(
            title: "branch-swap",
            style: .branchSwap,
            host: host,
            record: record
        )
        let stable = await runHandoffPanel(
            title: "stable-identity",
            style: .stableIdentity,
            host: host,
            record: record
        )
        record("- handoff branch-swap check=\(swap.check) cancel=\(swap.cancel) focusedAfter=\(swap.focusedAfter) reachedCancel=\(swap.reachedCancel)")
        record("- handoff stable-identity check=\(stable.check) cancel=\(stable.cancel) focusedAfter=\(stable.focusedAfter) reachedCancel=\(stable.reachedCancel)")
        if swap.focusedAfter.hasPrefix("none") || swap.focusedAfter == "none:0" {
            record("- contrast RED: if/else swap dropped AX focus off the action button")
        } else if swap.cancel == 0 {
            record("- contrast RED: if/else swap did not activate cancel from keyboard")
        }
        if stable.focusedAfter == "handoff-cancel" && stable.cancel > 0 {
            record("- contrast control: stable identity kept cancel focused and keyboard-activated")
        }
        host.makeKeyAndOrderFront(nil)
    }

    private static func runHandoffPanel(
        title: String,
        style: HandoffStyle,
        host: NSWindow,
        record: (String) -> Void
    ) async -> HandoffResult {
        let taps = HandoffTaps()
        let panel = NSWindow(
            contentRect: NSRect(x: host.frame.minX + 40, y: host.frame.minY + 80, width: 420, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "331-404 \(title)"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: HandoffContrastView(style: style, taps: taps))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<10 where !panel.isKeyWindow {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await pause(50)
        }
        record("- \(title) window key=\(panel.isKeyWindow)")
        let started = await activateByKeyboardOnPanel(
            identifier: "handoff-check",
            window: panel,
            record: record,
            succeeded: { taps.check > 0 }
        )
        await pause(120)
        let after = RealUIInput.observeFocus(window: panel, targetIdentifier: "handoff-cancel")
        record("- \(title) after start: started=\(started) \(after.line(step: -1)) firstResponder remains KeyViewProxy residual if id empty")
        var reached = after.matches(identifier: "handoff-cancel")
        if !reached {
            for step in 1...12 {
                _ = RealUIInput.sendKey("\t", keyCode: 48, to: panel)
                await pause(80)
                let snap = RealUIInput.observeFocus(window: panel, targetIdentifier: "handoff-cancel")
                record(snap.line(step: step))
                if snap.matches(identifier: "handoff-cancel") {
                    reached = true
                    record("- AX focus reached handoff-cancel at Tab step \(step)")
                    break
                }
            }
        }
        if reached {
            _ = RealUIInput.sendKey(" ", keyCode: 49, to: panel)
            await pause(200)
        } else {
            record("- \(title) FAIL: Tab did not reach handoff-cancel after swap; no forced focus")
        }
        let result = HandoffResult(
            check: taps.check,
            cancel: taps.cancel,
            focusedAfter: after.identifier.isEmpty ? "none:\(after.focusedCopyError)" : after.identifier,
            reachedCancel: reached
        )
        panel.close()
        return result
    }

    private static func activateByKeyboardOnPanel(
        identifier: String,
        window: NSWindow,
        record: (String) -> Void,
        succeeded: () -> Bool
    ) async -> Bool {
        let start = RealUIInput.observeFocus(window: window, targetIdentifier: identifier)
        record(start.line(step: 0))
        var reached = start.matches(identifier: identifier)
        if !reached {
            for step in 1...12 {
                _ = RealUIInput.sendKey("\t", keyCode: 48, to: window)
                await pause(80)
                let snap = RealUIInput.observeFocus(window: window, targetIdentifier: identifier)
                record(snap.line(step: step))
                if snap.matches(identifier: identifier) {
                    reached = true
                    record("- AX focus reached \(identifier) at Tab step \(step)")
                    break
                }
            }
        }
        guard reached else {
            record("- \(identifier) FAIL: Tab did not reach start button")
            return false
        }
        _ = RealUIInput.sendKey(" ", keyCode: 49, to: window)
        await pause(200)
        if succeeded() { return true }
        _ = RealUIInput.sendKey("\r", keyCode: 36, to: window)
        await pause(200)
        return succeeded()
    }

    private static func runContrastPanel(
        title: String,
        identifier: String,
        style: ContrastStyle,
        host: NSWindow,
        taps: ContrastTaps,
        record: (String) -> Void,
        count: () -> Int
    ) async -> Bool {
        let panel = NSWindow(
            contentRect: NSRect(x: host.frame.minX + 40, y: host.frame.minY + 80, width: 420, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "331-404 \(title)"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(
            rootView: SingleContrastButton(identifier: identifier, style: style, taps: taps)
        )
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<10 where !panel.isKeyWindow {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await pause(50)
        }
        record("- \(title) window key=\(panel.isKeyWindow)")
        if let target = RealUIInput.find(identifier: identifier) {
            record("- found \(identifier) role=\(target.role) title=\(target.title) children=\(RealUIInput.describeChildren(identifier: identifier))")
        } else {
            record("- missing \(identifier)")
        }
        let activated = await activateContrastButton(
            identifier: identifier,
            window: panel,
            record: record,
            count: count
        )
        panel.close()
        return activated
    }

    private static func activateContrastButton(
        identifier: String,
        window: NSWindow,
        record: (String) -> Void,
        count: () -> Int
    ) async -> Bool {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await pause(80)
        let before = count()
        let start = RealUIInput.observeFocus(window: window, targetIdentifier: identifier)
        record(start.line(step: 0))
        var reached = start.matches(identifier: identifier)
        if !reached {
            for step in 1...12 {
                _ = RealUIInput.sendKey("\t", keyCode: 48, to: window)
                await pause(80)
                let snap = RealUIInput.observeFocus(window: window, targetIdentifier: identifier)
                record(snap.line(step: step))
                if snap.matches(identifier: identifier) {
                    reached = true
                    record("- AX focus reached \(identifier) at Tab step \(step)")
                    break
                }
            }
        }
        guard reached else {
            record("- contrast FAIL: Tab did not reach \(identifier)")
            return false
        }
        _ = RealUIInput.sendKey(" ", keyCode: 49, to: window)
        await pause(200)
        if count() > before {
            record("- Space window-sendEvent activated \(identifier)")
            return true
        }
        _ = RealUIInput.sendAppKey(" ", keyCode: 49, to: window)
        await pause(200)
        if count() > before {
            record("- Space app-sendEvent activated \(identifier)")
            return true
        }
        _ = RealUIInput.sendResponderKey(" ", keyCode: 49, to: window)
        await pause(200)
        if count() > before {
            record("- Space firstResponder-keyDown activated \(identifier)")
            return true
        }
        record("- Space did not activate \(identifier); taps stayed \(count())")
        return false
    }

    private static func activateByKeyboard(
        identifier: String,
        window: NSWindow,
        vault: VaultViewModel,
        record: (String) -> Void
    ) async {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await pause(80)
        let before = activationSnapshot(identifier, vault: vault)
        record("- keyboard observe start target=\(identifier) windowKey=\(window.isKeyWindow) before=\(before)")
        if let target = RealUIInput.find(identifier: identifier) {
            record("- keyboard target found role=\(target.role) title=\(target.title) visible=\(target.visible) enabled=\(target.enabled) frame=\(NSStringFromRect(target.frame))")
        } else {
            record("- keyboard target missing from AX/AppKit")
        }
        let initial = RealUIInput.observeFocus(window: window, targetIdentifier: identifier)
        record(initial.line(step: 0))

        var tabDelivered = 0
        var tabSendFailed = false
        var anyReadable = initial.isReadable
        var lastUnreadableCode = initial.isReadable ? "" : initial.focusedCopyError
        var sawTarget = initial.matches(identifier: identifier)
        var reachedAt = sawTarget ? 0 : -1
        if sawTarget {
            record("- AX focus already on \(identifier) before Tab")
        }

        if !sawTarget {
            for step in 1...24 {
                window.makeKeyAndOrderFront(nil)
                let sent = RealUIInput.sendKey("\t", keyCode: 48, to: window)
                if !sent {
                    tabSendFailed = true
                    record("- Tab step \(step) sendKey failed windowKey=\(window.isKeyWindow)")
                    break
                }
                tabDelivered += 1
                await pause(80)
                let snap = RealUIInput.observeFocus(window: window, targetIdentifier: identifier)
                record(snap.line(step: step))
                if snap.isReadable {
                    anyReadable = true
                } else {
                    lastUnreadableCode = snap.focusedCopyError
                }
                if snap.matches(identifier: identifier) {
                    sawTarget = true
                    reachedAt = step
                    record("- AX focus reached \(identifier) at Tab step \(step)")
                    break
                }
            }
        }

        if sawTarget {
            let activated = await deliverActivationKeys(
                identifier: identifier,
                window: window,
                vault: vault,
                reachedAt: reachedAt,
                record: record
            )
            if !activated {
                let after = RealUIInput.observeFocus(window: window, targetIdentifier: identifier)
                record(after.line(step: 99))
                if !window.isKeyWindow {
                    record("- keyboard FAIL: 输入未投递 — AX 已确认目标聚焦，窗口不是 key window；未回退 AXPress/Registry/强制设焦")
                } else {
                    record("- keyboard FAIL: 输入未投递 — AX 已确认目标聚焦，同窗口 Space/Return（window.sendEvent / NSApp.sendEvent / firstResponder.keyDown）均未改变 check/cancel；未回退 AXPress/Registry/强制设焦")
                }
            }
            return
        }

        if tabSendFailed || tabDelivered == 0 {
            record("- keyboard FAIL: 输入未投递 — Tab sendKey 失败或未发出；未回退 AXPress/Registry/强制设焦")
            return
        }
        if !anyReadable {
            record("- keyboard FAIL: 焦点无法观测 — AXFocusedUIElement 不可读，返回码=\(lastUnreadableCode)；firstResponder 仅作辅线，不能证明无按钮焦点；未回退 AXPress/Registry/强制设焦")
            return
        }
        record("- keyboard FAIL: 可靠观察到目标不可达 — 发出 \(tabDelivered) 次 Tab 且 AXFocusedUIElement 可读，同 PID 焦点从未落到 \(identifier)；未回退 AXPress/Registry/强制设焦；不据此要求改系统全键盘设置")
    }

    private static func deliverActivationKeys(
        identifier: String,
        window: NSWindow,
        vault: VaultViewModel,
        reachedAt: Int,
        record: (String) -> Void
    ) async -> Bool {
        let keys: [(name: String, characters: String, code: UInt16)] = [
            ("Space", " ", 49),
            ("Return", "\r", 36)
        ]
        let methods: [(name: String, send: (String, UInt16, NSWindow) -> Bool)] = [
            ("window-sendEvent", RealUIInput.sendKey),
            ("app-sendEvent", RealUIInput.sendAppKey),
            ("firstResponder-keyDown", RealUIInput.sendResponderKey)
        ]
        for key in keys {
            for method in methods {
                window.makeKeyAndOrderFront(nil)
                let delivered = method.send(key.characters, key.code, window)
                record("- \(key.name) method=\(method.name) delivered=\(delivered) after AX focus at step \(reachedAt) windowKey=\(window.isKeyWindow) \(RealUIInput.keyboardFocusIdentifier(window: window))")
                await pause(250)
                if keyboardActionSucceeded(identifier: identifier, vault: vault) {
                    record("- keyboard PASS: \(key.name) via \(method.name) activated \(identifier) now=\(activationSnapshot(identifier, vault: vault))")
                    return true
                }
            }
        }
        return false
    }

    private static func capture(_ view: NSView, to url: URL, record: (String) -> Void) {
        view.layoutSubtreeIfNeeded()
        view.window?.contentView?.layoutSubtreeIfNeeded()
        if let window = view.window {
            window.displayIfNeeded()
            if let cgImage = CGWindowListCreateImage(
                CGRect.null,
                .optionIncludingWindow,
                CGWindowID(window.windowNumber),
                .bestResolution
            ) {
                let representation = NSBitmapImageRep(cgImage: cgImage)
                if let data = representation.representation(using: .png, properties: [:]) {
                    do {
                        try data.write(to: url, options: .atomic)
                        record("- screenshot \(url.lastPathComponent) bytes=\(data.count) source=window")
                        return
                    } catch {
                        record("- warn: window screenshot write \(error.localizedDescription)")
                    }
                }
            }
        }
        let target = view.window?.contentView ?? view
        guard let representation = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
            record("- FAIL: screenshot unavailable")
            return
        }
        target.cacheDisplay(in: target.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            record("- FAIL: PNG encoding failed")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            record("- screenshot \(url.lastPathComponent) bytes=\(data.count) source=view")
        } catch {
            record("- FAIL: screenshot write \(error.localizedDescription)")
        }
    }

    private static func pause(_ milliseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}

@MainActor
final class ContrastTaps {
    var focusable = 0
    var activate = 0
    var native = 0
}

enum ContrastStyle {
    case plainFocusable
    case activateFocusable
    case native
}

private struct SingleContrastButton: View {
    let identifier: String
    let style: ContrastStyle
    let taps: ContrastTaps

    var body: some View {
        button
            .padding(40)
            .frame(width: 380, height: 140)
    }

    @ViewBuilder
    private var button: some View {
        let title: String = {
            switch style {
            case .plainFocusable: return "Focusable"
            case .activateFocusable: return "Activate"
            case .native: return "Native"
            }
        }()
        let core = Button(title) {
            switch style {
            case .plainFocusable: taps.focusable += 1
            case .activateFocusable: taps.activate += 1
            case .native: taps.native += 1
            }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(identifier)
        switch style {
        case .plainFocusable:
            core.focusable()
        case .activateFocusable:
            core.focusable(interactions: .activate)
        case .native:
            core
        }
    }
}

@MainActor
final class HandoffTaps {
    var check = 0
    var cancel = 0
}

enum HandoffStyle {
    case branchSwap
    case stableIdentity
}

struct HandoffResult {
    var check: Int
    var cancel: Int
    var focusedAfter: String
    var reachedCancel: Bool
}

private struct HandoffContrastView: View {
    let style: HandoffStyle
    let taps: HandoffTaps
    @State private var started = false

    var body: some View {
        content
            .padding(40)
            .frame(width: 380, height: 140)
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .branchSwap:
            if started {
                handoffButton(title: "Cancel", identifier: "handoff-cancel") {
                    taps.cancel += 1
                }
            } else {
                handoffButton(title: "Check", identifier: "handoff-check") {
                    started = true
                    taps.check += 1
                }
            }
        case .stableIdentity:
            handoffButton(
                title: started ? "Cancel" : "Check",
                identifier: started ? "handoff-cancel" : "handoff-check"
            ) {
                if started {
                    taps.cancel += 1
                } else {
                    started = true
                    taps.check += 1
                }
            }
            .id("handoff-primary")
        }
    }

    private func handoffButton(
        title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(identifier)
            .focusable()
            .onKeyPress(.space) {
                action()
                return .handled
            }
            .onKeyPress(.return) {
                action()
                return .handled
            }
    }
}
#endif
