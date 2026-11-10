@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import XCTest

/// Simulated devices in one process: software keys, one in-memory transport
/// standing in for the account's private database, and one manual clock.
final class DeviceHarness {
    let clock = ManualDeviceClock()
    let transport = InMemoryDeviceTransport()

    func makeDevice(_ platform: DevicePlatform, list: PairedDeviceList = PairedDeviceList(),
                    identity: SoftwareDeviceIdentity = SoftwareDeviceIdentity()) -> SimulatedDevice {
        let store = InMemoryPairedDeviceListStore(list)
        return SimulatedDevice(identity: identity, store: store, platform: platform, harness: self)
    }

    /// Runs every pairing step: the person types the phone's code on the
    /// Mac and confirms on both devices. Returns the code the phone showed.
    @discardableResult
    func pair(_ mac: SimulatedDevice, _ phone: SimulatedDevice, file: StaticString = #filePath,
              line: UInt = #line) async throws -> PairingCode {
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        _ = try await mac.messenger.poll()
        _ = try await phone.messenger.poll()
        let macPhase = await mac.phase()
        guard case .enteringCode = macPhase else {
            XCTFail("the Mac asks for the code, not \(String(describing: macPhase))", file: file, line: line)
            throw DeviceMessengerError.notAwaitingConfirmation
        }
        let shownOnPhone = await phone.code()
        let phoneCode = try XCTUnwrap(shownOnPhone, "the phone shows a code", file: file, line: line)
        try await mac.messenger.confirmPairing(enteredCode: phoneCode.formatted, approvalReason: "Pair with the phone")
        try await phone.messenger.confirmPairing(approvalReason: "Pair with the Mac")
        _ = try await mac.messenger.poll()
        _ = try await phone.messenger.poll()
        return phoneCode
    }
}

final class SimulatedDevice {
    let identity: SoftwareDeviceIdentity
    let store: InMemoryPairedDeviceListStore
    let platform: DevicePlatform
    private let registryStore: any PairedDeviceListStore
    private(set) var messenger: DeviceMessenger
    private unowned let harness: DeviceHarness

    /// `registryStore` replaces `store` behind the messenger when given.
    init(identity: SoftwareDeviceIdentity, store: InMemoryPairedDeviceListStore, platform: DevicePlatform,
         harness: DeviceHarness, registryStore: (any PairedDeviceListStore)? = nil) {
        self.identity = identity
        self.store = store
        self.platform = platform
        self.harness = harness
        self.registryStore = registryStore ?? store
        messenger = Self.messenger(identity, self.registryStore, platform, harness)
    }

    var id: DeviceID { messenger.deviceID }

    /// The same keys and stored list in a new process: sessions, processed
    /// message IDs and pending checks are gone.
    func restart() {
        messenger = Self.messenger(identity, registryStore, platform, harness)
    }

    func devices() async throws -> [PairedDevice] {
        try await messenger.pairedDevices()
    }

    func entry(for other: SimulatedDevice) async throws -> PairedDevice? {
        try await devices().first { $0.deviceID == other.id }
    }

    func phase() async -> PairingPhase? {
        await messenger.pairingPhase
    }

    /// The code this device shows; only a responder shows one.
    func code() async -> PairingCode? {
        if case .showingCode(let code, _, _) = await phase() { return code }
        return nil
    }

    /// The code this device derived, read from inside the module. Tests use
    /// it where the person would read the code off the other device before
    /// the test delivered it there.
    func derivedCode() async -> PairingCode? {
        await messenger.testingSessionCode()
    }

    /// Confirms as the person would: an initiator types `code` (by default
    /// the code it derived), a responder confirms without typing.
    func confirm(typing code: PairingCode? = nil) async throws {
        guard await messenger.testingSessionRole() == .initiator else {
            return try await messenger.confirmPairing(approvalReason: "Pair")
        }
        var typed = code
        if typed == nil { typed = await derivedCode() }
        try await messenger.confirmPairing(enteredCode: typed?.formatted ?? "000000", approvalReason: "Pair")
    }

    func pairingID() async -> PairingID? {
        if case .paired(_, let pairingID) = await phase() { return pairingID }
        return nil
    }

    @discardableResult
    func poll() async throws -> InboxReport {
        try await messenger.poll()
    }

    private static func messenger(_ identity: SoftwareDeviceIdentity, _ store: any PairedDeviceListStore,
                                  _ platform: DevicePlatform, _ harness: DeviceHarness) -> DeviceMessenger {
        DeviceMessenger(identity: identity, platform: platform, registry: PairedDeviceRegistry(store: store),
                        transport: harness.transport, clock: harness.clock)
    }
}

extension DeviceMessenger {
    func testingSessionCode() -> PairingCode? { session?.code }
    func testingSessionRole() -> PairingRole? { session?.role }
    func testingCanSign() -> Bool { session?.confirmationBytes != nil }
}

extension PairingPhase {
    var endReason: PairingEndReason? {
        if case .ended(let reason) = self { return reason }
        return nil
    }
}

extension InMemoryDeviceTransport {
    /// Delivers everything except envelopes of the given kind.
    func dropping(_ kind: MessageKind, from sender: DeviceID? = nil) {
        interceptor = { envelope in
            envelope.kind == Int64(kind.rawValue) && (sender == nil || envelope.sender == sender?.text) ? .drop : .deliver
        }
    }

    func delaying(_ kind: MessageKind, from sender: DeviceID? = nil) {
        interceptor = { envelope in
            envelope.kind == Int64(kind.rawValue) && (sender == nil || envelope.sender == sender?.text) ? .delay : .deliver
        }
    }

    func lastSent(_ kind: MessageKind, from sender: DeviceID) -> DeviceEnvelope? {
        sentEnvelopes.last { $0.kind == Int64(kind.rawValue) && $0.sender == sender.text }
    }
}

// XCTest's assertions take synchronous autoclosures; these take async ones.

func XCTAssertEqualAsync<T: Equatable>(_ expression1: @autoclosure () async throws -> T,
                                       _ expression2: @autoclosure () async throws -> T,
                                       _ message: @autoclosure () -> String = "",
                                       file: StaticString = #filePath, line: UInt = #line) async {
    do {
        let first = try await expression1()
        let second = try await expression2()
        XCTAssertEqual(first, second, message(), file: file, line: line)
    } catch {
        XCTFail("threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertNotEqualAsync<T: Equatable>(_ expression1: @autoclosure () async throws -> T,
                                          _ expression2: @autoclosure () async throws -> T,
                                          _ message: @autoclosure () -> String = "",
                                          file: StaticString = #filePath, line: UInt = #line) async {
    do {
        let first = try await expression1()
        let second = try await expression2()
        XCTAssertNotEqual(first, second, message(), file: file, line: line)
    } catch {
        XCTFail("threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertTrueAsync(_ expression: @autoclosure () async throws -> Bool, _ message: @autoclosure () -> String = "",
                        file: StaticString = #filePath, line: UInt = #line) async {
    await XCTAssertEqualAsync(try await expression(), true, message(), file: file, line: line)
}

func XCTAssertFalseAsync(_ expression: @autoclosure () async throws -> Bool, _ message: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) async {
    await XCTAssertEqualAsync(try await expression(), false, message(), file: file, line: line)
}

func XCTAssertNilAsync<T>(_ expression: @autoclosure () async throws -> T?, _ message: @autoclosure () -> String = "",
                          file: StaticString = #filePath, line: UInt = #line) async {
    do {
        let value = try await expression()
        XCTAssertNil(value, message(), file: file, line: line)
    } catch {
        XCTFail("threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertNotNilAsync<T>(_ expression: @autoclosure () async throws -> T?, _ message: @autoclosure () -> String = "",
                             file: StaticString = #filePath, line: UInt = #line) async {
    do {
        let value = try await expression()
        XCTAssertNotNil(value, message(), file: file, line: line)
    } catch {
        XCTFail("threw \(error) \(message())", file: file, line: line)
    }
}

func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?, _ message: @autoclosure () -> String = "",
                       file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, message(), file: file, line: line)
}
