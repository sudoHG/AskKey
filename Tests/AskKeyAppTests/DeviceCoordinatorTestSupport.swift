import AskKeyDevicesTestSupport
import AskKeyTestSupport
import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyDevices
@testable import AskKeyVault

/// The Mac's coordinator on a real temporary library, with software keys,
/// the in-memory transport, a manual clock and a simulated iPhone. Polling
/// runs only when a test asks for it.
@MainActor
final class DeviceCoordinatorHarness {
    let library: AgentAccessPolicyTestLibrary
    let clock = ManualDeviceClock(Date())
    let transport = InMemoryDeviceTransport()
    let backend: FakeDeviceServicesBackend
    let script = DeviceTestScript()
    let phone: SimulatedPairingPhone
    private(set) var coordinator: DeviceCoordinator

    init() throws {
        library = try AgentAccessPolicyTestLibrary()
        try library.vault.beginManagementSession(using: .allow)
        backend = FakeDeviceServicesBackend(transport: transport, clock: clock)
        phone = SimulatedPairingPhone(transport: transport, clock: clock)
        coordinator = Self.makeCoordinator(vault: library.vault, backend: backend, script: script)
    }

    func close() throws {
        coordinator.stop()
        try library.close()
    }

    /// The same keychain, library and inbox state in a new App process.
    func relaunch() async {
        coordinator.stop()
        coordinator = Self.makeCoordinator(vault: library.vault, backend: backend, script: script)
        await coordinator.launch()
    }

    private static func makeCoordinator(vault: Vault, backend: FakeDeviceServicesBackend,
                                        script: DeviceTestScript) -> DeviceCoordinator {
        DeviceCoordinator(environment: DeviceCoordinatorEnvironment(
            vault: vault,
            backend: backend,
            inboxState: VaultDeviceInboxStateStore(vault: vault),
            authenticate: { reason in await script.authenticate(reason) },
            isManagementSessionActive: { script.managementActive },
            displayName: { "Synthetic Mac" },
            log: { script.record($0) },
            automaticPolling: false,
            sleep: { _ in }
        ))
    }

    var macDeviceID: DeviceID? { coordinator.services?.deviceID }

    /// Starts pairing and has the iPhone scan the QR code; the Mac then
    /// freezes the request and sends its challenge.
    func startAndScan() async throws -> PairingPeer {
        await coordinator.startPairing()
        guard case .showingQRCode(let text, _) = coordinator.pairing else {
            XCTFail("the Mac shows the QR code, not \(String(describing: coordinator.pairing))")
            throw DeviceMessengerError.notAwaitingConfirmation
        }
        try await phone.scan(text)
        await coordinator.refresh()
        guard case .waitingForIPhone(let peer, _) = coordinator.pairing else {
            XCTFail("the Mac waits for the iPhone, not \(String(describing: coordinator.pairing))")
            throw DeviceMessengerError.notAwaitingConfirmation
        }
        return peer
    }

    /// Runs the pairing up to the code entry and returns the iPhone's code.
    func reachCodeEntry() async throws -> String {
        _ = try await startAndScan()
        try await phone.poll()
        await coordinator.refresh()
        guard case .enteringCode = coordinator.pairing, let code = await phone.shownCode() else {
            XCTFail("the Mac asks for the code the iPhone shows, not \(String(describing: coordinator.pairing))")
            throw DeviceMessengerError.notAwaitingConfirmation
        }
        return code
    }

    /// A complete pairing with the simulated iPhone, its delivery check answered.
    func pairPhone() async throws {
        let code = try await reachCodeEntry()
        await coordinator.enterPairingCode(code)
        await coordinator.confirmPairing()
        try await phone.confirm()
        try await phone.poll()
        await coordinator.refresh()
        guard case .paired = coordinator.pairing else {
            XCTFail("the Mac paired, not \(String(describing: coordinator.pairing))")
            throw DeviceMessengerError.notAwaitingConfirmation
        }
        await coordinator.cancelPairing()
        try await phone.poll()
        await coordinator.refresh()
    }

    /// Every confirmation the Mac sent.
    func macConfirmations() -> [DeviceEnvelope] {
        guard let mac = macDeviceID else { return [] }
        return transport.sentEnvelopes.filter { $0.kind == Int64(MessageKind.pairingConfirmation.rawValue) && $0.sender == mac.text }
    }

    func macSent(_ kind: MessageKind) -> [DeviceEnvelope] {
        guard let mac = macDeviceID else { return [] }
        return transport.sentEnvelopes.filter { $0.kind == Int64(kind.rawValue) && $0.sender == mac.text }
    }

    /// What the coordinator publishes, for checks that nothing shows the code.
    func publishedState() -> String {
        [String(reflecting: coordinator.pairing), String(reflecting: coordinator.pairingFeedback),
         String(reflecting: coordinator.devices), String(reflecting: coordinator.availability)].joined(separator: "\n")
    }

    /// Opens a message addressed to `identity`, as that device would.
    static func open(_ envelope: DeviceEnvelope, by identity: SoftwareDeviceIdentity, now: Date) throws -> InnerMessage {
        let ownID = DeviceID(messagePublicKey: identity.messagePublicKey)
        let routing = try MessageCodec.routing(of: envelope, ownID: ownID, now: now)
        return try MessageCodec.open(envelope, routing: routing, ownID: ownID, identity: identity, preSharedKey: nil, now: now)
    }
}

/// What the person and the system do while a test runs.
@MainActor
final class DeviceTestScript {
    var managementActive = true
    /// Each prompt's answer, in order; afterwards every prompt succeeds.
    var authenticationResults: [ManagementAuthenticationResult] = []
    var duringAuthentication: (@MainActor () async -> Void)?
    private(set) var authenticationReasons: [String] = []
    private let events = DeviceEventLog()

    func authenticate(_ reason: String) async -> ManagementAuthenticationResult {
        authenticationReasons.append(reason)
        await duringAuthentication?()
        return authenticationResults.isEmpty ? .authenticated(.allow) : authenticationResults.removeFirst()
    }

    nonisolated func record(_ event: DeviceServicesEvent) { events.append(event) }

    var loggedEvents: [DeviceServicesEvent] { events.all }
}

final class DeviceEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DeviceServicesEvent] = []

    func append(_ event: DeviceServicesEvent) { lock.withLock { events.append(event) } }
    var all: [DeviceServicesEvent] { lock.withLock { events } }
}
