import AskKeyDevices
import UserNotifications
import XCTest

/// The content handler, content replacement on every path, and the parts.
final class NotificationServiceTests: XCTestCase {
    private func originalContent(_ userInfo: [AnyHashable: Any]) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Ask Key"
        content.subtitle = "Enter 123 456 on your Mac"
        content.body = "Tap Allow"
        content.categoryIdentifier = "attacker.actions"
        content.threadIdentifier = "attacker"
        content.userInfo = userInfo
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    }

    /// Runs the extension on a push and returns every content it handed over.
    private func run(_ world: NotificationWorld, _ userInfo: [AnyHashable: Any],
                     whileRunning: ((NotificationService) async -> Void)? = nil,
                     afterRunning: ((NotificationService) -> Void)? = nil) async throws -> [UNNotificationContent] {
        let service = NotificationService()
        let environment = try world.environment()
        service.makeEnvironment = { environment }
        let delivered = Box<[UNNotificationContent]>([])
        service.didReceive(originalContent(userInfo)) { delivered.value.append($0) }
        await whileRunning?(service)
        await service.work?.value
        afterRunning?(service)
        return delivered.value
    }

    private func assertGeneric(_ content: UNNotificationContent?, recordName: String?,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let content = try XCTUnwrap(content, file: file, line: line)
        let english = try NotificationStrings.strings("en")
        XCTAssertEqual(content.title, english["push.message.title"], file: file, line: line)
        XCTAssertEqual(content.body, english["push.message.body"], file: file, line: line)
        XCTAssertEqual(content.subtitle, "", file: file, line: line)
        XCTAssertEqual(content.attachments.count, 0, file: file, line: line)
        XCTAssertEqual(content.categoryIdentifier, "askkey.message", file: file, line: line)
        XCTAssertEqual(content.threadIdentifier, "", file: file, line: line)
        XCTAssertEqual(content.interruptionLevel, .active, file: file, line: line)
        XCTAssertNil(content.badge, file: file, line: line)
        let expected: [String: String] = recordName.map { ["askkey.recordName": $0] } ?? [:]
        XCTAssertEqual(content.userInfo as? [String: String], expected, file: file, line: line)
    }

    func testTheUserInfoKeyIsTheOneTheAppReads() {
        XCTAssertEqual(NotificationContentBuilder.recordNameKey, "askkey.recordName")
    }

    func testEveryFailureReplacesTheContentWithTheGenericText() async throws {
        let world = try NotificationWorld(approver: false)
        let (sealed, push) = try world.sendRequest()
        let name = sealed.sealed.envelope.recordName

        try assertGeneric(try await run(world, push).first, recordName: name)
        try assertGeneric(try await run(world, ["aps": ["alert": "Approve now"], "extra": "x"]).first, recordName: nil)
        world.keychain.readsFail = true
        try assertGeneric(try await run(world, push).first, recordName: name)
        XCTAssertEqual(world.sent, [])
    }

    func testAVerifiedRequestKeepsTheGenericShapeWithTheSentence() async throws {
        let world = try NotificationWorld()
        let (sealed, push) = try world.sendRequest()

        let delivered = try await run(world, push)

        XCTAssertEqual(delivered.count, 1)
        let content = try XCTUnwrap(delivered.first)
        XCTAssertEqual(content.title, "Ask Key")
        XCTAssertEqual(content.body, "\u{201C}Codex\u{201D} on \u{201C}Studio Mac\u{201D} wants to use \u{201C}GitHub Token\u{201D} to run deploy.sh")
        XCTAssertEqual(content.subtitle, "")
        XCTAssertEqual(content.attachments.count, 0)
        XCTAssertEqual(content.categoryIdentifier, "askkey.message")
        XCTAssertEqual(content.threadIdentifier, "mac_" + world.mac.identity.id.text)
        XCTAssertEqual(content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(content.userInfo as? [String: String], ["askkey.recordName": sealed.sealed.envelope.recordName])
    }

    func testWhenTimeRunsOutTheGenericTextIsDeliveredOnceAndNothingIsSent() async throws {
        let world = try NotificationWorld()
        let (sealed, push) = try world.sendRequest()
        let gate = Gate()
        world.cloud.fetchGate = gate

        let delivered = try await run(world, push) { service in
            while gate.arrived == 0 { await Task.yield() }
            service.serviceExtensionTimeWillExpire()
            gate.open()
        }

        XCTAssertEqual(delivered.count, 1)
        try assertGeneric(delivered.first, recordName: sealed.sealed.envelope.recordName)
        XCTAssertEqual(world.sent, [])
        world.assertStayedInItsLane()
    }

    func testTheTimeRunningOutAfterDeliveryChangesNothing() async throws {
        let world = try NotificationWorld()
        let push = try world.sendRequest().push

        let delivered = try await run(world, push, afterRunning: { $0.serviceExtensionTimeWillExpire() })

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.interruptionLevel, .timeSensitive)
    }

    func testTheTimeRunningOutTwiceDeliversOnce() async throws {
        let world = try NotificationWorld()
        let push = try world.sendRequest().push
        let gate = Gate()
        world.cloud.fetchGate = gate

        let delivered = try await run(world, push) { service in
            while gate.arrived == 0 { await Task.yield() }
            service.serviceExtensionTimeWillExpire()
            service.serviceExtensionTimeWillExpire()
            gate.open()
        }

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.interruptionLevel, .active)
    }

    func testADeliveryCheckGetsTheGenericText() async throws {
        let world = try NotificationWorld()
        let transport = CloudKitDeviceTransport(service: world.cloud, deviceID: world.mac.identity.id, platform: .macOS,
                                                clock: world.clock, log: { _ in })
        let messenger = DeviceMessenger(identity: world.mac.identity, platform: .macOS,
                                        registry: PairedDeviceRegistry(store: world.mac.listStore), transport: transport,
                                        clock: world.clock, inboxToken: nil)
        let check = try await messenger.sendDeliveryCheck(to: world.phone.id)

        let delivered = try await run(world, world.push(for: check.text))

        try assertGeneric(delivered.first, recordName: check.text)
        XCTAssertEqual(world.sent.count, 1)
    }
}

final class NotificationTextTests: XCTestCase {
    func testAPartAtItsLimitIsKeptAndOneCharacterMoreIsShortenedInTheMiddle() {
        let exact = String(repeating: "a", count: 24)
        XCTAssertEqual(NotificationText.part(exact, limit: 24), exact)
        let longer = "abcdefghijklmnopqrstuvwxy"
        XCTAssertEqual(NotificationText.part(longer, limit: 24), "abcdefghijkl…opqrstuvwxy")
        XCTAssertEqual(NotificationText.part(String(repeating: "b", count: 40), limit: 32).count, 32)
    }

    func testPartsCountCharactersNotScalars() {
        // Two scalars per character; 30 of them stay within the display-name rule's 64 scalars.
        let accented = "e\u{301}"
        let shortened = NotificationText.part(String(repeating: accented, count: 30), limit: 24)
        XCTAssertEqual(shortened.count, 24)
        XCTAssertEqual(shortened, String(repeating: accented, count: 12) + "…" + String(repeating: accented, count: 11))
        // The display-name rule runs first: it keeps whole characters within 64 scalars.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(NotificationText.part(String(repeating: family, count: 30), limit: 24),
                       String(repeating: family, count: 12))
    }

    func testPartsAreCleanedAndCannotCloseTheQuotes() {
        XCTAssertEqual(NotificationText.part("  \u{202E}My \u{201C}Mac\u{201D}\u{2066}\u{0007} ", limit: 24), "My \"Mac\"")
    }

    func testTheExecutableKeepsOnlyItsLastPathComponent() {
        XCTAssertEqual(NotificationText.lastPathComponent("/usr/local/bin/tool"), "tool")
        XCTAssertEqual(NotificationText.lastPathComponent("deploy.sh"), "deploy.sh")
        XCTAssertEqual(NotificationText.lastPathComponent("dir/"), "dir")
    }

    func testBothLanguagesHaveEveryStringWithFourPlaceholders() throws {
        let english = try NotificationStrings.strings("en")
        let chinese = try NotificationStrings.strings("zh-Hans")
        let keys: Set = [NotificationStrings.title, NotificationStrings.genericBody, NotificationStrings.requestBody,
                         NotificationStrings.localAgent]
        XCTAssertEqual(Set(english.keys), keys)
        XCTAssertEqual(Set(chinese.keys), keys)
        for key in keys {
            XCTAssertNotEqual(english[key], chinese[key], key)
        }
        for table in [english, chinese] {
            XCTAssertEqual(table[NotificationStrings.requestBody]?.components(separatedBy: "%@").count, 5)
        }
        XCTAssertEqual(english[NotificationStrings.title], "Ask Key")
    }
}

final class NotificationStateStoreTests: XCTestCase {
    private let macA = DeviceID(rawValue: Data(repeating: 1, count: 16))!
    private let macB = DeviceID(rawValue: Data(repeating: 2, count: 16))!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheBudgetIsPerMacAndLastsTwoMinutes() {
        let keychain = TestKeychain()
        let store = NotificationStateStore(keychain: ExtensionKeychain(store: keychain))
        XCTAssertTrue(store.claimTimeSensitive(for: macA, at: start))
        XCTAssertFalse(store.claimTimeSensitive(for: macA, at: start.addingTimeInterval(119)))
        XCTAssertTrue(store.claimTimeSensitive(for: macB, at: start.addingTimeInterval(1)))
        XCTAssertTrue(store.claimTimeSensitive(for: macA, at: start.addingTimeInterval(120)))
        XCTAssertEqual(Set(keychain.writes), [ExtensionKeychain.stateAccount])
    }

    func testAClockThatMovedBackFarDoesNotBlockTheBudget() {
        let store = NotificationStateStore(keychain: ExtensionKeychain(store: TestKeychain()))
        XCTAssertTrue(store.claimTimeSensitive(for: macA, at: start))
        XCTAssertTrue(store.claimTimeSensitive(for: macA, at: start.addingTimeInterval(-3600)))
    }

    func testAnUnreadableItemUsesTheActiveLevelAndAGarbledOneStartsAgain() {
        let keychain = TestKeychain()
        let store = NotificationStateStore(keychain: ExtensionKeychain(store: keychain))
        keychain.readsFail = true
        XCTAssertFalse(store.claimTimeSensitive(for: macA, at: start))
        keychain.readsFail = false
        keychain.seed(Data("garbled".utf8), for: ExtensionKeychain.stateAccount)
        XCTAssertTrue(store.claimTimeSensitive(for: macA, at: start))
    }

    func testDeliveryChecksAreKeptWithoutContentAndBounded() throws {
        let keychain = TestKeychain()
        let store = NotificationStateStore(keychain: ExtensionKeychain(store: keychain))
        for index in 0..<25 { store.recordDeliveryCheck("record-\(index)", at: start.addingTimeInterval(Double(index))) }
        let data = try XCTUnwrap(keychain.stored(ExtensionKeychain.stateAccount))
        let state = try JSONDecoder().decode(NotificationServiceState.self, from: data)
        XCTAssertEqual(state.deliveryChecks.map(\.recordName), (5..<25).map { "record-\($0)" })
    }
}

/// A value a `@Sendable` test closure can set.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
