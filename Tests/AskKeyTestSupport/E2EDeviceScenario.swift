import AskKeyAppKit
import AskKeyDevices
import Foundation
import Observation

/// The other side of the Devices screenshots (#288): the E2E App's fake
/// device services and a simulated iPhone in the same process, on the
/// factory from #287. The runner clicks the App's real controls and plays
/// the iPhone and the iCloud account through one-shot fixture commands.
/// The iPhone's code never leaves this process: the step that enters it
/// plays the person typing it, and nothing writes it anywhere.
@MainActor
enum E2EDeviceScenario {
    static let scenarioPrefix = "screenshots-devices"
    static let phoneName = "Synthetic iPhone"
    static let commands = ["phone-scan", "phone-reveal", "phone-complete", "phone-poll", "account-signed-out", "trace"]

    private static var backend: FakeDeviceServicesBackend?
    private static var phone: SimulatedPairingPhone?
    private static var task: Task<Void, Never>?
    private static var transitions: [String] = []
    private static var control: URL?

    static func isRequested(_ scenario: String) -> Bool {
        scenario.hasPrefix(scenarioPrefix)
    }

    /// The factory the E2E App passes as `makeDeviceServices`.
    static func makeBackend() -> any DeviceServicesBackend {
        let backend = FakeDeviceServicesBackend(account: .available(userRecordName: "_synthetic-e2e-account"))
        self.backend = backend
        phone = SimulatedPairingPhone(transport: backend.transport, clock: backend.clock)
        return backend
    }

    /// Runs each command once when its file appears, then removes the file
    /// and writes `device-<command>.json` with the outcome.
    static func start(control: URL) {
        self.control = control
        recordPairingTransitions(control: control)
        task = Task { @MainActor in
            while !Task.isCancelled {
                for command in commands {
                    let file = control.appendingPathComponent("command-\(command).txt")
                    guard FileManager.default.fileExists(atPath: file.path) else { continue }
                    try? FileManager.default.removeItem(at: file)
                    var report: [String: Any] = ["command": command]
                    do {
                        try await run(command)
                        report["ok"] = true
                    } catch {
                        report["ok"] = false
                        report["error"] = String(describing: error)
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                        try? data.write(to: control.appendingPathComponent("device-\(command).json"), options: .atomic)
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    static func stop() {
        task?.cancel()
        task = nil
    }

    /// A pairing state by case name; the end and start-failure reasons in
    /// full, which carry no code, QR payload or name.
    private static func describe(_ state: PairingSheetState) -> String {
        switch state {
        case .ended, .failed: return String(describing: state)
        default: return String(String(describing: state).prefix { $0 != "(" })
        }
    }

    /// Writes `device-transitions.json` with the coordinator's state at
    /// launch and after each change the Devices section reads: pairing by
    /// case name only (the QR payload holds the pairing secret),
    /// availability, account, identity and the number of devices. A failed
    /// capture then shows where the session went.
    private static func recordPairingTransitions(control: URL, reason: String = "launch") {
        guard let coordinator = DeviceServicesHost.coordinator else {
            transitions.append("\(Date().timeIntervalSince1970) no device coordinator")
            writeTransitions(control: control)
            return
        }
        let state = coordinator.pairing.map(describe) ?? "none"
        transitions.append("\(Date().timeIntervalSince1970) \(reason): pairing=\(state) availability=\(coordinator.availability) "
            + "account=\(coordinator.account) identity=\(coordinator.hasIdentity) devices=\(coordinator.devices.count)")
        writeTransitions(control: control)
        withObservationTracking {
            _ = (coordinator.pairing, coordinator.availability, coordinator.account, coordinator.hasIdentity,
                 coordinator.devices.count)
        } onChange: {
            Task { @MainActor in recordPairingTransitions(control: control, reason: "change") }
        }
    }

    private static func writeTransitions(control: URL) {
        let report = ["transitions": transitions]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
            try? data.write(to: control.appendingPathComponent("device-transitions.json"), options: .atomic)
        }
    }

    private static func run(_ command: String) async throws {
        guard let coordinator = DeviceServicesHost.coordinator, let phone, let backend else {
            throw E2EDeviceScenarioError.notInstalled
        }
        switch command {
        case "phone-scan":
            guard case .showingQRCode(let text, _) = coordinator.pairing else { throw E2EDeviceScenarioError.noQRCode }
            try await phone.scan(text, name: phoneName)
        case "phone-reveal":
            // The Mac's challenge follows its next poll; the reveal follows the challenge.
            try await repeatUntil { try await phone.poll(); return await phone.shownCode() != nil }
        case "phone-complete":
            // The person types the code the iPhone shows and confirms on the
            // Mac (system authentication is simulated), then on the iPhone.
            guard let code = await phone.shownCode() else { throw E2EDeviceScenarioError.noCode }
            await coordinator.enterPairingCode(code)
            await coordinator.confirmPairing()
            try await phone.confirm()
            try await repeatUntil {
                try await phone.poll()
                await coordinator.refresh()
                if case .paired = coordinator.pairing { return true }
                return false
            }
        case "phone-poll":
            // The iPhone app opens and answers the delivery check.
            try await repeatUntil {
                try await phone.poll()
                await coordinator.refresh()
                if case .reached = coordinator.devices.first?.reachability { return true }
                return false
            }
        case "trace":
            // T6 TEMP #298, revert before merge: what Pair a Device… did on the runner's click.
            guard let control else { throw E2EDeviceScenarioError.notInstalled }
            let data = try JSONSerialization.data(withJSONObject: ["trace": DevicesPairingTrace.lines], options: [.prettyPrinted])
            try data.write(to: control.appendingPathComponent("device-trace.json"), options: .atomic)
        case "account-signed-out":
            backend.accountState = .noAccount
            backend.signalAccountChange()
        default:
            throw E2EDeviceScenarioError.unknownCommand
        }
    }

    /// Repeats `step` for up to ten seconds until it reports success.
    private static func repeatUntil(_ step: () async throws -> Bool) async throws {
        for _ in 0..<50 {
            if try await step() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw E2EDeviceScenarioError.timedOut
    }
}

enum E2EDeviceScenarioError: Error {
    case notInstalled, noQRCode, noCode, timedOut, unknownCommand
}
