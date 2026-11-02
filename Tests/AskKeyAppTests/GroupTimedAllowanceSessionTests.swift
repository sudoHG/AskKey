import AppKit
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit
@testable import AskKeyVault

final class GroupTimedAllowanceSessionTests: XCTestCase {
    func testEverySessionRevocationPathEndsTheWholeGroupAndItsPreparedDeliveries() throws {
        for event in Event.allCases {
            let fixture = try Fixture(enabled: event != .enableWhileLocked)
            defer { try? fixture.library.close() }
            let group = try fixture.grantGroup()
            let tickets = try group.members.map { try fixture.approvals.submit(fixture.read($0), trustedCredentialDeadline: .none) }
            let leases = try group.members.map { try fixture.lease($0) }
            defer { leases.forEach { $0.finish() } }
            let pending = try fixture.approvals.submit(fixture.read("unrelated"), trustedCredentialDeadline: .none)
            let once = try fixture.approvals.submit(fixture.read("once"), trustedCredentialDeadline: .none)
            _ = try fixture.approvals.decide(requestID: once.requestID, capability: once.capability, decision: .once)

            try fixture.fire(event)

            // Validate a prepared delivery first: the backstop must not need a
            // prior list refresh or another Broker operation to end the grant.
            for lease in leases {
                XCTAssertThrowsError(try lease.performAuthorizedSpawn { XCTFail("A revoked group must not spawn") }, "\(event)")
            }
            XCTAssertTrue(fixture.approvals.activeTimedAllowances().isEmpty, "\(event)")
            XCTAssertEqual(fixture.probe.cleaned, Set(group.members.map(\.credentialID)), "\(event)")
            for (member, ticket) in zip(group.members, tickets) {
                XCTAssertNil(fixture.approvals.timedAllowanceDeadline(credentialID: member.credentialID), "\(event)")
                XCTAssertEqual(try fixture.approvals.status(requestID: ticket.requestID, capability: ticket.capability), .cancelled)
                XCTAssertEqual(try fixture.approvals.submit(fixture.read(member), trustedCredentialDeadline: .none).state, .pending)
            }
            XCTAssertEqual(try fixture.approvals.status(requestID: pending.requestID, capability: pending.capability), .pending)
            XCTAssertEqual(try fixture.approvals.status(requestID: once.requestID, capability: once.capability), .approved)
            XCTAssertFalse(try fixture.vault.isAgentAccessPaused())
            if event == .enableWhileLocked {
                let following = try fixture.pendingGroup()
                XCTAssertThrowsError(try fixture.vault.decideAgentApproval(requestID: following.requestID,
                    capability: following.capability, decision: .timedAllowGroup(duration: 60))) {
                    XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision)
                }
            }
        }
    }

    func testOptOutPreservesWholeGroupTicketsAndRuntimeLeasesOnLockSleepAndSessionChanges() throws {
        for event in Event.sessionEvents {
            let fixture = try Fixture(enabled: false)
            defer { try? fixture.library.close() }
            let group = try fixture.grantGroup()
            let tickets = try group.members.map { try fixture.approvals.submit(fixture.read($0), trustedCredentialDeadline: .none) }
            let leases = try group.members.map { try fixture.lease($0) }
            defer { leases.forEach { $0.finish() } }

            try fixture.fire(event)

            XCTAssertEqual(fixture.approvals.activeTimedAllowances(), [group], "\(event)")
            XCTAssertTrue(fixture.probe.cleaned.isEmpty, "\(event)")
            for ticket in tickets {
                XCTAssertEqual(try fixture.approvals.status(requestID: ticket.requestID, capability: ticket.capability), .approved)
            }
            for lease in leases { XCTAssertNoThrow(try lease.performAuthorizedSpawn {}) }
            for member in group.members {
                XCTAssertEqual(try fixture.approvals.submit(fixture.read(member), trustedCredentialDeadline: .none).state, .approved)
            }
        }
    }

    func testGroupGrantsRespectLockedSleepingAndSwitchedOutSessionsOnlyWhenEnabled() throws {
        for enabled in [false, true] {
            for event in Event.sessionEvents {
                let fixture = try Fixture(enabled: enabled)
                defer { try? fixture.library.close() }
                let pending = try fixture.pendingGroup()
                try fixture.fire(event)
                let decide = {
                    try fixture.vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
                                                         decision: .timedAllowGroup(duration: 60))
                }
                if enabled {
                    XCTAssertThrowsError(try decide(), "\(event)") { XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision) }
                    XCTAssertTrue(fixture.approvals.activeTimedAllowances().isEmpty)
                    XCTAssertEqual(try fixture.approvals.status(requestID: pending.requestID, capability: pending.capability), .pending)
                    XCTAssertEqual(fixture.approvals.pendingRequests().first?.groupAllowanceSnapshot?.members.count, 2)
                } else {
                    XCTAssertEqual(try decide().state, .approved)
                    XCTAssertEqual(fixture.approvals.activeTimedAllowances().first?.members.count, 2)
                }
            }
        }
    }

    func testSessionEndAndResumeBeforeFinalGroupMutationRejectsStaleGenerationOnlyWhenEnabled() throws {
        for enabled in [false, true] {
            for event in Event.sessionEvents {
                let fixture = try Fixture(enabled: enabled)
                defer { try? fixture.library.close() }
                let pending = try fixture.pendingGroup()
                let decide = {
                    try fixture.approvals.decide(requestID: pending.requestID, capability: pending.capability,
                        decision: .timedAllowGroup(duration: 60), revalidate: {
                            try fixture.vault.agentAccessGate.beginSpawnAuthorization(validating: fixture.vault.revalidateAgentAccessPolicy)
                            fixture.vault.agentAccessGate.endSpawnAuthorization()
                            try fixture.fire(event)
                            _ = fixture.approvals.pendingRequests() // Observe a missed lock through the backstop.
                            fixture.resume(event)
                        })
                }
                if enabled {
                    XCTAssertThrowsError(try decide(), "\(event)") { XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision) }
                    XCTAssertTrue(fixture.approvals.activeTimedAllowances().isEmpty)
                    XCTAssertEqual(try fixture.approvals.status(requestID: pending.requestID, capability: pending.capability), .pending)
                    // The resumed session permits a fresh decision, but cannot
                    // restore the authority captured before the ending event.
                    XCTAssertEqual(try fixture.vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
                        decision: .timedAllowGroup(duration: 60)).state, .approved)
                } else {
                    XCTAssertEqual(try decide().state, .approved)
                }
            }
        }
    }

    func testLateUnlockedSampleAfterWillSleepCannotGrantGroupUntilDidWake() throws {
        let fixture = try Fixture(enabled: true)
        defer { try? fixture.library.close() }
        let pending = try fixture.pendingGroup()
        try fixture.fire(.sleep)
        fixture.screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
        fixture.workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertThrowsError(try fixture.vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllowGroup(duration: 60))) { XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision) }
        XCTAssertTrue(fixture.approvals.activeTimedAllowances().isEmpty)
        fixture.resume(.sleep)
        XCTAssertEqual(try fixture.vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllowGroup(duration: 60)).state, .approved)
        XCTAssertEqual(fixture.approvals.activeTimedAllowances().first?.members.count, 2)
    }

    private enum Event: CaseIterable {
        case lock, sleep, sessionSwitch, backstop, enableWhileLocked
        static let sessionEvents: [Event] = [.lock, .sleep, .sessionSwitch, .backstop]
    }

    private final class Fixture {
        let library: AgentAccessPolicyTestLibrary
        var vault: Vault { library.vault }
        var approvals: BrokerApprovalStateMachine { vault.approvalRequests }
        let screen: NotificationCenter
        let workspace: NotificationCenter
        let probe: Probe
        let observer: TimedAllowanceSessionObserver

        init(enabled: Bool) throws {
            let library = try AgentAccessPolicyTestLibrary()
            self.library = library
            let screen = NotificationCenter()
            let workspace = NotificationCenter()
            let probe = Probe()
            self.screen = screen
            self.workspace = workspace
            self.probe = probe
            let vault = library.vault
            try vault.beginManagementSession(using: .allow)
            try vault.updateTimedAllowance(enabled: true, minutes: 30)
            try vault.updateEndTimedAllowancesOnLock(enabled, using: .allow)
            for name in ["Alpha", "Beta"] {
                _ = try vault.createTextCredential(.init(name: name, value: "synthetic-\(name)", groupName: "Project",
                    environmentVariable: name.uppercased(), permission: .ask), using: .allow)
            }
            vault.approvalRequests.configureAuthentication { _ in true }
            vault.approvalRequests.configureTimedAllowanceScreenState { probe.unlocked }
            vault.approvalRequests.configureTimedAllowanceSleepOffset { (100, 100) }
            observer = TimedAllowanceSessionObserver(screenNotifications: screen, workspaceNotifications: workspace,
                screenState: { probe.unlocked ? .unlocked : .locked },
                updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3) })
        }

        func pendingGroup() throws -> BrokerApprovalTicket {
            guard case .approvalRequired(let tickets) = try vault.brokerTextCredentials(
                for: .init(operationID: UUID().uuidString, command: ["/usr/bin/true"], credentialNames: ["Alpha"]), cancellation: .init()) else {
                throw BrokerApprovalError.invalidDecision
            }
            return try XCTUnwrap(tickets.first)
        }

        func grantGroup() throws -> BrokerTimedAllowance {
            let ticket = try pendingGroup()
            _ = try vault.decideAgentApproval(requestID: ticket.requestID, capability: ticket.capability,
                                              decision: .timedAllowGroup(duration: 60))
            let group = try XCTUnwrap(approvals.activeTimedAllowances().first)
            XCTAssertEqual(group.members.map(\.name), ["Alpha", "Beta"])
            return group
        }

        func read(_ member: BrokerGroupAllowanceSnapshot.Member) -> BrokerApprovalOperationRequest {
            read(member.credentialID, digest: member.metadataDigest)
        }

        func read(_ id: String, digest: String? = nil) -> BrokerApprovalOperationRequest {
            .init(operationID: UUID().uuidString, credentialID: id, targetID: id, operation: .read,
                  payloadDigest: String(repeating: "a", count: 64), readProjectionDigest: digest)
        }

        func lease(_ member: BrokerGroupAllowanceSnapshot.Member) throws -> BrokerRuntimeReadAuthorization {
            let operation = read(member)
            let ticket = try approvals.submit(operation, trustedCredentialDeadline: .none)
            let lease = try XCTUnwrap(approvals.consumeForRuntime([
                .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: operation)
            ]))
            let probe = probe
            try lease.registerCleanup { probe.clean(member.credentialID) }
            return lease
        }

        func fire(_ event: Event) throws {
            switch event {
            case .lock:
                probe.setUnlocked(false)
                screen.post(name: .init("com.apple.screenIsLocked"), object: nil)
            case .sleep: workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
            case .sessionSwitch: workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            case .backstop: probe.setUnlocked(false)
            case .enableWhileLocked:
                probe.setUnlocked(false)
                screen.post(name: .init("com.apple.screenIsLocked"), object: nil)
                XCTAssertFalse(approvals.activeTimedAllowances().isEmpty, "The setting is still off")
                try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
            }
        }

        func resume(_ event: Event) {
            probe.setUnlocked(true)
            switch event {
            case .sleep: workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
            case .sessionSwitch: workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            default: screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
            }
        }
    }

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var screenUnlocked = true
        private var cleanedIDs: Set<String> = []
        var unlocked: Bool { lock.lock(); defer { lock.unlock() }; return screenUnlocked }
        var cleaned: Set<String> { lock.lock(); defer { lock.unlock() }; return cleanedIDs }
        func setUnlocked(_ value: Bool) { lock.lock(); defer { lock.unlock() }; screenUnlocked = value }
        func clean(_ id: String) { lock.lock(); defer { lock.unlock() }; cleanedIDs.insert(id) }
    }
}
