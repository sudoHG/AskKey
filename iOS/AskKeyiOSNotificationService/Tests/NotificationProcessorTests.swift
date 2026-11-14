import AskKeyDevices
import CloudKit
import XCTest

final class NotificationProcessorTests: XCTestCase {
    // MARK: A verified request from a Mac this iPhone approves for

    func testAVerifiedRequestFromAnApproverMacShowsTheCardSentenceAndSendsOneReceipt() async throws {
        let world = try NotificationWorld()
        let (sealed, push) = try world.sendRequest()

        let request = try await world.requestNotification(push)

        XCTAssertEqual(request.body, "\u{201C}Codex\u{201D} on \u{201C}Studio Mac\u{201D} wants to use \u{201C}GitHub Token\u{201D} to run deploy.sh")
        XCTAssertEqual(request.threadIdentifier, "mac_" + world.mac.identity.id.text)
        XCTAssertTrue(request.isTimeSensitive)
        XCTAssertEqual(world.sent.count, 1)
        let receipt = try XCTUnwrap(world.sent.first)
        XCTAssertEqual(receipt.kind, Int64(MessageKind.approvalReceipt.rawValue))
        XCTAssertEqual(receipt.recordName, ApprovalReceipt.receiptID(for: sealed.request.responseID).text)
        guard case .approval(let verified) = try world.verifyOnMac(receipt), case .receipt = verified.message else {
            return XCTFail("the Mac does not verify the receipt")
        }
        XCTAssertEqual(verified.requestDigest, sealed.requestDigest)
        world.assertStayedInItsLane()
    }

    func testTheNotificationHoldsOnlyTheFourNames() async throws {
        let world = try NotificationWorld()
        let display = ApprovalRequestDisplay(
            requesterName: "Codex", purpose: "PURPOSE-TEXT", credentialName: "Staging DB",
            commandLine: "psql --host db.example.test --password-file SECRET-ARG", workingDirectory: "~/FOLDER-NAME",
            executableName: "/opt/FOLDER-TWO/psql",
            deliveryRows: [ApprovalDeliveryRow(kind: .environmentVariable, label: "LABEL-NAME", variable: "VARIABLE_NAME"),
                           ApprovalDeliveryRow(kind: .temporaryFile, label: "Key", variable: "FILE_VARIABLE")])

        let request = try await world.requestNotification(try world.sendRequest(display: display).push)

        XCTAssertEqual(request.body, "\u{201C}Codex\u{201D} on \u{201C}Studio Mac\u{201D} wants to use \u{201C}Staging DB\u{201D} to run psql")
        for fragment in ["PURPOSE", "SECRET", "--host", "FOLDER", "LABEL", "VARIABLE", "~", "example"] {
            XCTAssertFalse(request.body.contains(fragment), fragment)
        }
    }

    func testEveryPartIsCleanedAndShortenedToItsLimit() async throws {
        let world = try NotificationWorld(macName: "Mac \u{201C}Pro\u{201D} of the build lab")
        let display = ApprovalRequestDisplay(
            requesterName: "Agent with a rather long name", purpose: "",
            credentialName: "A \u{201C}quoted\u{201D} credential with a long name", commandLine: "./x",
            workingDirectory: "", executableName: "a-very-long-program-name-for-testing.sh",
            deliveryRows: [ApprovalDeliveryRow(kind: .environmentVariable, label: "", variable: "TOKEN")])

        let request = try await world.requestNotification(try world.sendRequest(display: display).push)

        let requester = "Agent with a…r long name"
        let mac = "Mac \"Pro\" of…e build lab"
        let credential = "A \"quoted\" crede…ith a long name"
        let executable = "a-very-long-prog…-for-testing.sh"
        XCTAssertEqual([requester, mac, credential, executable].map(\.count), [24, 24, 32, 32])
        XCTAssertEqual(request.body, "\u{201C}\(requester)\u{201D} on \u{201C}\(mac)\u{201D} wants to use \u{201C}\(credential)\u{201D} to run \(executable)")
    }

    func testAnUnnamedAgentIsTheLocalAgent() async throws {
        let world = try NotificationWorld()
        var display = NotificationWorld.sampleDisplay
        display.requesterName = ""

        let request = try await world.requestNotification(try world.sendRequest(display: display).push)

        XCTAssertTrue(request.body.hasPrefix("\u{201C}Local Agent\u{201D} on "), request.body)
    }

    func testTheSentenceInSimplifiedChinese() async throws {
        let world = try NotificationWorld()
        let chinese = try NotificationStrings.table("zh-Hans")

        let request = try await world.requestNotification(try world.sendRequest().push, strings: chinese)

        let expected = String(format: chinese.text(NotificationStrings.requestBody), "Codex", "Studio Mac", "GitHub Token",
                              "deploy.sh")
        XCTAssertEqual(request.body, expected)
        let english = try await world.requestNotification(try world.sendRequest().push)
        XCTAssertNotEqual(request.body, english.body)
    }

    // MARK: The time-sensitive budget

    func testOnlyTheFirstRequestFromAMacInTwoMinutesIsTimeSensitive() async throws {
        let world = try NotificationWorld()
        let other = try world.addMac(named: "Mini")

        let first = try await world.process(try world.sendRequest().push).request
        world.clock.advance(by: 60)
        let second = try await world.process(try world.sendRequest().push).request
        let otherMac = try await world.process(try world.sendRequest(from: other).push).request
        world.clock.advance(by: 59)
        let third = try await world.process(try world.sendRequest().push).request
        world.clock.advance(by: 2)
        let fourth = try await world.process(try world.sendRequest().push).request

        XCTAssertEqual([first, second, otherMac, third, fourth].map { $0?.isTimeSensitive }, [true, false, true, false, true])
        XCTAssertEqual(otherMac?.threadIdentifier, "mac_" + other.identity.id.text)
        XCTAssertEqual(world.sent.count, 5, "one receipt per request")
        world.assertStayedInItsLane()
    }

    func testABudgetThatCannotBeRecordedUsesTheActiveLevel() async throws {
        let world = try NotificationWorld()
        world.keychain.writesFail = true

        let request = try await world.process(try world.sendRequest().push).request

        XCTAssertEqual(request?.isTimeSensitive, false)
        XCTAssertEqual(world.sent.count, 1)
    }

    // MARK: Delivery checks

    func testADeliveryCheckIsAnsweredWithTheMessageKey() async throws {
        let world = try NotificationWorld()
        let transport = CloudKitDeviceTransport(service: world.cloud, deviceID: world.mac.identity.id, platform: .macOS,
                                                clock: world.clock, log: { _ in })
        let messenger = DeviceMessenger(identity: world.mac.identity, platform: .macOS,
                                        registry: PairedDeviceRegistry(store: world.mac.listStore), transport: transport,
                                        clock: world.clock, inboxToken: nil)
        let check = try await messenger.sendDeliveryCheck(to: world.phone.id)

        let decision = try await world.process(world.push(for: check.text))

        XCTAssertEqual(decision, .answeredDeliveryCheck)
        XCTAssertEqual(world.sent.map(\.kind), [Int64(MessageKind.deliveryCheckReply.rawValue)])
        world.assertStayedInItsLane()
        world.clock.advance(by: 1)
        _ = try await messenger.poll()
        let entry = try await messenger.pairedDevices().first
        guard case .replied? = entry?.lastDeliveryCheck else {
            return XCTFail("the Mac did not accept the reply: \(String(describing: entry?.lastDeliveryCheck))")
        }
        let state = try XCTUnwrap(world.keychain.stored(ExtensionKeychain.stateAccount))
        let records = try JSONDecoder().decode(NotificationServiceState.self, from: state).deliveryChecks
        XCTAssertEqual(records.map(\.recordName), [check.text])
        XCTAssertEqual(world.cloud.calls.filter { $0.hasPrefix("deleteRecords inbox_" + world.phone.id.text) }, [])
        XCTAssertEqual(world.phone.approvalKeyUses, 0)
    }

    func testAReplyThatCannotBeSentIsNotRecorded() async throws {
        let world = try NotificationWorld()
        let transport = CloudKitDeviceTransport(service: world.cloud, deviceID: world.mac.identity.id, platform: .macOS,
                                                clock: world.clock, log: { _ in })
        let messenger = DeviceMessenger(identity: world.mac.identity, platform: .macOS,
                                        registry: PairedDeviceRegistry(store: world.mac.listStore), transport: transport,
                                        clock: world.clock, inboxToken: nil)
        let check = try await messenger.sendDeliveryCheck(to: world.phone.id)
        world.cloud.sendsFail = true

        let decision = try await world.process(world.push(for: check.text))

        XCTAssertEqual(decision, .generic(.replyFailed))
        XCTAssertNil(world.keychain.stored(ExtensionKeychain.stateAccount))
    }

    func testTheExtensionsItemIsTheOneTheADRNames() {
        XCTAssertEqual(DataProtectionKeychain.service, "com.sudohg.askkey.ios.devices")
        XCTAssertEqual(ExtensionKeychain.stateAccount, "notification-service-state")
    }

    // MARK: Generic text, and nothing sent

    private func assertGeneric(_ world: NotificationWorld, _ push: [AnyHashable: Any], _ reason: GenericReason,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let decision = try await world.process(push)
        XCTAssertEqual(decision, .generic(reason), file: file, line: line)
        XCTAssertEqual(world.sent, [], "sent something", file: file, line: line)
        world.assertStayedInItsLane(file: file, line: line)
    }

    func testAPushForAnotherDeviceStaysGeneric() async throws {
        let world = try NotificationWorld()
        let (sealed, _) = try world.sendRequest()
        let other = TestIdentity()
        try await assertGeneric(world, world.push(for: sealed.sealed.envelope.recordName, device: other.id), .otherDevice)
    }

    func testAPushNeedsThisInboxsZoneAndSubscription() async throws {
        let world = try NotificationWorld()
        let name = try world.sendRequest().request.sealed.envelope.recordName
        let zone = CloudKitInboxLayout.zoneName(for: world.phone.id)
        try await assertGeneric(world, world.push(for: name, subscription: "attacker"), .otherDevice)
        try await assertGeneric(world, world.push(for: name, device: TestIdentity().id, subscription: zone + "_alert"),
                                .otherDevice)
    }

    func testAPushThatNamesNoMessageStaysGeneric() async throws {
        let world = try NotificationWorld()
        try await assertGeneric(world, ["aps": ["alert": "Approve now", "mutable-content": 1]], .notAMessagePush)
        try await assertGeneric(world, world.push(for: "not-a-message-id"), .notAMessagePush)
    }

    func testAPhoneNotUnlockedSinceItStartedStaysGeneric() async throws {
        let world = try NotificationWorld()
        let push = try world.sendRequest().push
        world.keychain.readsFail = true
        try await assertGeneric(world, push, .keysUnavailable)
        XCTAssertEqual(world.cloud.calls, [], "fetched without keys")
    }

    func testMissingOrBrokenKeysStayGeneric() async throws {
        let world = try NotificationWorld()
        let push = try world.sendRequest().push
        world.restoreFails = true
        try await assertGeneric(world, push, .keysUnavailable)
        world.restoreFails = false
        world.phone.isUnusable = true
        try await assertGeneric(world, push, .keysUnavailable)
        world.keychain.seed(nil, for: DeviceKeychainAccount.messageKey)
        world.keychain.seed(nil, for: DeviceKeychainAccount.agreementKey)
        world.keychain.seed(nil, for: DeviceKeychainAccount.approvalKey)
        try await assertGeneric(world, push, .noIdentity)
    }

    func testAnUnreadableListStaysGeneric() async throws {
        let world = try NotificationWorld()
        let push = try world.sendRequest().push
        world.keychain.seed(Data("not a list".utf8), for: DeviceKeychainAccount.pairedDevices)
        try await assertGeneric(world, push, .listUnavailable)
    }

    func testARequestFromAMacWithoutTheApprovalFlagStaysGeneric() async throws {
        let world = try NotificationWorld(approver: false)
        try await assertGeneric(world, try world.sendRequest().push, .notApprover)
    }

    func testARequestFromADeviceThatIsNotAMacStaysGeneric() async throws {
        let world = try NotificationWorld()
        let phoneLike = try world.addMac(named: "Other iPhone", platform: .iOS)
        try await assertGeneric(world, try world.sendRequest(from: phoneLike).push, .notFromMac)
    }

    func testAClosedMessageStaysGeneric() async throws {
        let world = try NotificationWorld()
        let request = try world.sealRequest()
        let closed = try DeviceMessageSealer(identity: world.mac.identity, clock: world.clock)
            .sealApprovalClosed(.expired, requestDigest: request.requestDigest, to: world.mac.phoneEntry)
        try world.cloud.insert(closed.envelope)
        try await assertGeneric(world, world.push(for: closed.envelope.recordName), .notARequest)
    }

    func testARecordThatDoesNotVerifyStaysGeneric() async throws {
        let world = try NotificationWorld()
        let stranger = TestIdentity()
        let forged = try DeviceMessageSealer(identity: stranger, clock: world.clock)
            .sealApprovalRequest(NotificationWorld.sampleDisplay, bindingDigest: Data(repeating: 1, count: 32),
                                 deadline: world.clock.now().addingTimeInterval(300), launchTime: world.clock.now(),
                                 offers: .denyOrAllowOnce, timedDuration: 0,
                                 to: PairedDevice(card: try DeviceCard.make(identity: world.phone, platform: .iOS,
                                                                            createdAt: world.clock.now()),
                                                  pairingID: world.mac.pairingID, displayName: "x",
                                                  pairedAt: world.clock.now()))
        try world.cloud.insert(forged.sealed.envelope)
        try await assertGeneric(world, world.push(for: forged.sealed.envelope.recordName), .refused(.unknownSender))

        var tampered = try world.sealRequest().sealed.envelope
        tampered.body[tampered.body.count - 20] ^= 0x01
        try world.cloud.insert(tampered)
        let decision = try await world.process(world.push(for: tampered.recordName))
        guard case .generic(.refused) = decision else { return XCTFail("\(decision)") }

        let (_, expiredPush) = try world.sendRequest()
        world.clock.advance(by: 11 * 60)
        try await assertGeneric(world, expiredPush, .refused(.expired))
        XCTAssertEqual(world.sent, [])
    }

    func testAMissingRecordAFailedFetchOrNoContainerStaysGeneric() async throws {
        let world = try NotificationWorld()
        try await assertGeneric(world, world.push(for: MessageID.random().text), .notFound)
        let push = try world.sendRequest().push
        world.cloud.fetchesFail = true
        try await assertGeneric(world, push, .fetchFailed)
        world.cloud.fetchesFail = false
        world.hasContainer = false
        try await assertGeneric(world, push, .noContainer)
    }

    func testARecordCloudKitFailsToReturnStaysGeneric() async throws {
        let world = try NotificationWorld()
        let push = try world.sendRequest().push
        world.cloud.recordsFail = true
        try await assertGeneric(world, push, .fetchFailed)
    }

    func testApprovalStoppedWhileTheRecordIsFetchedStaysGeneric() async throws {
        let world = try NotificationWorld()
        let push = try world.sendRequest().push
        let gate = Gate()
        world.cloud.fetchGate = gate
        let environment = try world.environment()
        let running = Task { await NotificationProcessor(environment: environment).process(PushInfo(userInfo: push)) }
        while gate.arrived == 0 { await Task.yield() }
        try world.setApprover(world.mac, enabled: false)
        gate.open()

        let decision = await running.value

        XCTAssertEqual(decision, .generic(.notApprover))
        XCTAssertEqual(world.sent, [])
    }

    func testAMissingInboxZoneIsNeverRecreated() async throws {
        let world = try NotificationWorld()
        let push = try world.sendRequest().push
        world.cloud.zoneMissing = true
        try await assertGeneric(world, push, .notFound)
        XCTAssertEqual(world.cloud.calls.filter { $0.hasPrefix("saveZone") }, [])
    }

    func testAFailedReceiptStillShowsTheRequest() async throws {
        let world = try NotificationWorld()
        let push = try world.sendRequest().push
        world.cloud.sendsFail = true

        let request = try await world.process(push).request

        XCTAssertNotNil(request)
        XCTAssertEqual(world.sent, [])
    }
}
