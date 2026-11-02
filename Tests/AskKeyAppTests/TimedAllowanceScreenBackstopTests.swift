import AppKit
import XCTest
@testable import AskKeyBroker
@testable import AskKeyAppKit
@testable import AskKeyVault

final class TimedAllowanceScreenBackstopTests: XCTestCase {
    func testMissingLockNotificationBlocksCachedReadsAndPreparedTimedDeliveryOnlyWhenEnabled() throws {
        for enabled in [false, true] {
            for blocked in [AgentApprovalScreenState.locked, .unknown] {
                let library = try AgentAccessPolicyTestLibrary()
                defer { try? library.close() }
                let vault = library.vault
                let probe = ScreenProbe(.unlocked)
                let approvals = vault.approvalRequests
                approvals.configureTimedAllowanceScreenState { probe.unlocked() }
                try vault.updateEndTimedAllowancesOnLock(enabled, using: .allow)
                approvals.configureAuthentication { _ in true }
                try vault.beginManagementSession(using: .allow)
                for (name, permission) in [("TIMED", CredentialPermission.ask), ("ALLOW", .allowed)] {
                    _ = try vault.createTextCredential(.init(name: name, value: "synthetic", permission: permission), using: .allow)
                }
                let request = BrokerTextRunRequest(command: ["/usr/bin/true"], credentialNames: ["TIMED"])
                guard case let .approvalRequired(tickets) = try vault.brokerTextCredentials(for: request, cancellation: .init()) else {
                    return XCTFail("Expected Ask approval")
                }
                let timed = try XCTUnwrap(tickets.first)
                _ = try vault.decideAgentApproval(requestID: timed.requestID, capability: timed.capability, decision: .timedAllow(duration: 120))
                guard case let .resolved(_, _, optionalTimedLease) = try vault.brokerTextCredentials(for: request, cancellation: .init()),
                      case let .resolved(_, _, optionalAllowLease) = try vault.brokerTextCredentials(
                        for: .init(command: ["/usr/bin/true"], credentialNames: ["ALLOW"]), cancellation: .init()) else {
                    return XCTFail("Expected prepared deliveries")
                }
                let timedLease = try XCTUnwrap(optionalTimedLease)
                let allowLease = try XCTUnwrap(optionalAllowLease)
                defer { timedLease.finish(); timedLease.cleanup(); allowLease.finish(); allowLease.cleanup() }
                let cached = try submit(approvals, credential: "cached")
                _ = try approvals.decide(requestID: cached.requestID, capability: cached.capability, decision: .timedAllow(duration: 120))
                let onceRequest = BrokerApprovalOperationRequest(operationID: UUID().uuidString,
                    credentialID: "once", targetID: "once", operation: .read, payloadDigest: String(repeating: "a", count: 64))
                let once = try approvals.submit(onceRequest, trustedCredentialDeadline: .none)
                _ = try approvals.decide(requestID: once.requestID, capability: once.capability, decision: .once)
                probe.set(blocked) // No lock notification is delivered.
                let next = try submit(approvals, credential: "cached")
                XCTAssertEqual(next.state, enabled ? .pending : .approved)
                XCTAssertEqual(try approvals.status(requestID: cached.requestID, capability: cached.capability), enabled ? .cancelled : .approved)
                if enabled {
                    XCTAssertThrowsError(try timedLease.performAuthorizedSpawn(afterAuthorization: {}, spawn: { XCTFail("Must not spawn") }))
                    XCTAssertNil(approvals.timedAllowanceDeadline(credentialID: "cached"))
                } else {
                    try timedLease.performAuthorizedSpawn(afterAuthorization: {}, spawn: {})
                    XCTAssertEqual(probe.reads, 0, "The setting-off path must never consult the live provider")
                }
                try allowLease.performAuthorizedSpawn(afterAuthorization: {}, spawn: {})
                XCTAssertEqual(try approvals.consume(requestID: once.requestID, capability: once.capability, operationRequest: onceRequest), .consumed)
                let write = try submit(approvals, credential: "write", operation: .modify)
                XCTAssertEqual(try vault.decideAgentApproval(requestID: write.requestID, capability: write.capability, decision: .once).state, .approved)
                probe.set(.unlocked)
                XCTAssertEqual(try submit(approvals, credential: "cached").state, enabled ? .pending : .approved)
                if !enabled { XCTAssertEqual(probe.reads, 0) }
            }
        }
    }

    func testLiveScreenBackstopRejectsFinalTimedGrantWithoutNotificationAndPreservesPending() throws {
        for blocked in [AgentApprovalScreenState.locked, .unknown] {
            let library = try AgentAccessPolicyTestLibrary()
            defer { try? library.close() }
            let vault = library.vault
            try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
            let probe = ScreenProbe(.unlocked)
            let approvals = vault.approvalRequests
            approvals.configureTimedAllowanceScreenState { probe.unlocked() }
            approvals.configureAuthentication { _ in true }
            let pending = try submit(approvals, credential: "pending")
            XCTAssertThrowsError(try approvals.decide(requestID: pending.requestID, capability: pending.capability,
                decision: .timedAllow(duration: 120), revalidate: { probe.set(blocked) })) {
                XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision)
            }
            XCTAssertNil(approvals.timedAllowanceDeadline(credentialID: "pending"))
            XCTAssertEqual(try approvals.status(requestID: pending.requestID, capability: pending.capability), .pending)
            probe.set(.unlocked)
            XCTAssertEqual(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
                decision: .timedAllow(duration: 120)).state, .approved)
        }
    }

    func testPreparedTimedFileDeliveryChecksLiveScreenAtSpawnWithoutAnotherBrokerMutation() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        let probe = ScreenProbe(.unlocked)
        let approvals = vault.approvalRequests
        approvals.configureTimedAllowanceScreenState { probe.unlocked() }
        approvals.configureAuthentication { _ in true }
        try vault.beginManagementSession(using: .allow)
        _ = try vault.createFileCredential(.init(name: "FILE",
            snapshot: .init(originalFilename: "synthetic.txt", bytes: Data("synthetic".utf8)),
            environmentVariable: "FILE_PATH", permission: .ask), using: .allow)
        let request = BrokerTextRunRequest(command: ["/usr/bin/true"], credentialNames: ["FILE"])
        guard case let .approvalRequired(tickets) = try vault.brokerTextCredentials(for: request, cancellation: .init()) else {
            return XCTFail("Expected Ask approval")
        }
        let timed = try XCTUnwrap(tickets.first)
        _ = try vault.decideAgentApproval(requestID: timed.requestID, capability: timed.capability, decision: .timedAllow(duration: 120))
        guard case let .resolved(credentials, _, optionalLease) = try vault.brokerTextCredentials(for: request, cancellation: .init()) else {
            return XCTFail("Expected prepared file delivery")
        }
        let lease = try XCTUnwrap(optionalLease)
        defer { lease.finish(); lease.cleanup() }
        let path = try XCTUnwrap(credentials.first?.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        probe.set(.locked)
        // No notification, status query, submission or other Broker mutation
        // can revoke this lease before the actual final-spawn check.
        XCTAssertThrowsError(try lease.performAuthorizedSpawn(afterAuthorization: {}, spawn: { XCTFail("Must not spawn") }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        probe.set(.unlocked)
        XCTAssertThrowsError(try lease.performAuthorizedSpawn(afterAuthorization: {}, spawn: { XCTFail("Revoked authority cannot revive") }))
    }

    func testFreshLiveScreenStateRecoversStaleUnknownWithoutUnlockNotification() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        let probe = ScreenProbe(.unknown)
        let approvals = vault.approvalRequests
        approvals.configureTimedAllowanceScreenState { probe.unlocked() }
        let observer = SynchronousTimedAllowanceSessionObserver(screenNotifications: .init(), workspaceNotifications: .init(),
            screenState: { probe.current }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3, sleepOffsetUpperBound: $4) })
        defer { withExtendedLifetime(observer) {} }
        approvals.configureAuthentication { _ in true }
        probe.set(.unlocked)
        let pending = try submit(approvals, credential: "pending")
        XCTAssertEqual(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)).state, .approved)
    }

    func testSleepWithoutLockOrDidWakeAllowsFreshTimedGrantButNeverRevivesRevokedAllowance() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        let approvals = vault.approvalRequests
        let offset = SleepOffsetProbe()
        approvals.configureTimedAllowanceSleepOffset { offset.current }
        approvals.configureTimedAllowanceScreenState { true }
        approvals.configureAuthentication { _ in true }
        let workspace = TimedAllowanceTestNotificationCenter()
        let observer = SynchronousTimedAllowanceSessionObserver(screenNotifications: .init(), workspaceNotifications: workspace,
            screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3, sleepOffsetUpperBound: $4) })
        defer { withExtendedLifetime(observer) {} }
        let previous = try submit(approvals, credential: "timed")
        _ = try vault.decideAgentApproval(requestID: previous.requestID, capability: previous.capability,
            decision: .timedAllow(duration: 120))
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        // The console is unlocked after sleep without a password. Deliver no
        // wake, unlock or become-active event before the next live refresh.
        let fresh = try submit(approvals, credential: "timed")
        XCTAssertEqual(fresh.state, .pending)
        XCTAssertEqual(try approvals.status(requestID: previous.requestID, capability: previous.capability), .cancelled)
        XCTAssertNil(approvals.timedAllowanceDeadline(credentialID: "timed"))
        XCTAssertThrowsError(try vault.decideAgentApproval(requestID: fresh.requestID, capability: fresh.capability,
            decision: .timedAllow(duration: 120)), "Unlocked before actual sleep must not clear willSleep") {
            XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertEqual(try approvals.status(requestID: fresh.requestID, capability: fresh.capability), .pending)
        offset.set(lower: 101, upper: 101) // The system slept, but didWake was missed.
        XCTAssertEqual(try vault.decideAgentApproval(requestID: fresh.requestID, capability: fresh.capability,
            decision: .timedAllow(duration: 120)).state, .approved)
        XCTAssertEqual(try approvals.status(requestID: previous.requestID, capability: previous.capability), .cancelled)
    }

    func testSleepWithLiveLockedOrOverlappingClockBoundsKeepsTimedGrantsBlocked() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        let approvals = vault.approvalRequests
        let screen = ScreenProbe(.unlocked)
        let offset = SleepOffsetProbe()
        offset.set(lower: 100, upper: 110)
        approvals.configureTimedAllowanceSleepOffset { offset.current }
        approvals.configureTimedAllowanceScreenState { screen.unlocked() }
        approvals.configureAuthentication { _ in true }
        let workspace = TimedAllowanceTestNotificationCenter()
        let observer = SynchronousTimedAllowanceSessionObserver(screenNotifications: .init(), workspaceNotifications: workspace,
            screenState: { screen.current }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3, sleepOffsetUpperBound: $4) })
        defer { withExtendedLifetime(observer) {} }
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        let pending = try submit(approvals, credential: "sleep-window")
        offset.set(lower: 105, upper: 115)
        XCTAssertThrowsError(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)), "Sampling jitter is not evidence of sleep")
        offset.set(lower: 111, upper: 120)
        for blocked in [AgentApprovalScreenState.locked, .unknown] {
            screen.set(blocked)
            XCTAssertThrowsError(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
                decision: .timedAllow(duration: 120)), "Proven sleep still requires a live unlocked console")
            XCTAssertEqual(try approvals.status(requestID: pending.requestID, capability: pending.capability), .pending)
            XCTAssertNil(approvals.timedAllowanceDeadline(credentialID: "sleep-window"))
        }
        screen.set(.unlocked)
        XCTAssertEqual(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)).state, .approved)
    }

    func testLateUnlockOrBecomeActiveBeforeActualSleepCannotClearSleepTransition() throws {
        for liveProvider in [false, true] {
            for event in [Notification.Name("com.apple.screenIsUnlocked"), NSWorkspace.sessionDidBecomeActiveNotification] {
                let library = try AgentAccessPolicyTestLibrary()
                defer { try? library.close() }
                let vault = library.vault
                try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
                let approvals = vault.approvalRequests
                let offset = SleepOffsetProbe()
                approvals.configureTimedAllowanceSleepOffset { offset.current }
                if liveProvider { approvals.configureTimedAllowanceScreenState { true } }
                approvals.configureAuthentication { _ in true }
                let screen = TimedAllowanceTestNotificationCenter()
                let workspace = TimedAllowanceTestNotificationCenter()
                let observer = SynchronousTimedAllowanceSessionObserver(screenNotifications: screen, workspaceNotifications: workspace,
                    screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3, sleepOffsetUpperBound: $4) })
                defer { withExtendedLifetime(observer) {} }
                let previous = try submit(approvals, credential: "timed")
                _ = try vault.decideAgentApproval(requestID: previous.requestID, capability: previous.capability,
                    decision: .timedAllow(duration: 120))
                workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
                let center = event == NSWorkspace.sessionDidBecomeActiveNotification ? workspace : screen
                center.post(name: event, object: nil)
                XCTAssertTrue(approvals.timedAllowanceSessionSleeping)
                XCTAssertEqual(approvals.timedAllowanceSleepOffsetAtSleep, 100)
                let fresh = try submit(approvals, credential: "timed")
                XCTAssertThrowsError(try vault.decideAgentApproval(requestID: fresh.requestID, capability: fresh.capability,
                    decision: .timedAllow(duration: 120))) { XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision) }
                XCTAssertEqual(try approvals.status(requestID: fresh.requestID, capability: fresh.capability), .pending)
                offset.set(lower: 101, upper: 101)
                center.post(name: event, object: nil) // No didWake; this unlocked sample proves recovery.
                XCTAssertFalse(approvals.timedAllowanceSessionSleeping)
                XCTAssertEqual(try vault.decideAgentApproval(requestID: fresh.requestID, capability: fresh.capability,
                    decision: .timedAllow(duration: 120)).state, .approved)
                let generation = approvals.timedAllowanceSessionGeneration
                center.post(name: event, object: nil)
                XCTAssertEqual(approvals.timedAllowanceSessionGeneration, generation)
                XCTAssertEqual(try approvals.status(requestID: fresh.requestID, capability: fresh.capability), .approved)
                XCTAssertEqual(try approvals.status(requestID: previous.requestID, capability: previous.capability), .cancelled)
            }
        }
    }

    func testLockOrResignAfterMissedWakePreservesOriginalSleepOffsetAndCannotRearmSleep() throws {
        for liveProvider in [false, true] {
            for resign in [false, true] {
                let library = try AgentAccessPolicyTestLibrary()
                defer { try? library.close() }
                let vault = library.vault
                try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
                let approvals = vault.approvalRequests
                let state = ScreenProbe(.unlocked)
                let offset = SleepOffsetProbe()
                approvals.configureTimedAllowanceSleepOffset { offset.current }
                if liveProvider { approvals.configureTimedAllowanceScreenState { state.unlocked() } }
                approvals.configureAuthentication { _ in true }
                let screen = TimedAllowanceTestNotificationCenter()
                let workspace = TimedAllowanceTestNotificationCenter()
                let observer = SynchronousTimedAllowanceSessionObserver(screenNotifications: screen, workspaceNotifications: workspace,
                    screenState: { state.current }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3, sleepOffsetUpperBound: $4) })
                defer { withExtendedLifetime(observer) {} }
                workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
                offset.set(lower: 101, upper: 101) // Actual sleep, with no didWake.
                state.set(.locked)
                (resign ? workspace : screen).post(name: resign ? NSWorkspace.sessionDidResignActiveNotification
                    : .init("com.apple.screenIsLocked"), object: nil)
                XCTAssertEqual(approvals.timedAllowanceSleepOffsetAtSleep, 100, "Only willSleep may record the offset")
                state.set(.unlocked)
                (resign ? workspace : screen).post(name: resign ? NSWorkspace.sessionDidBecomeActiveNotification
                    : .init("com.apple.screenIsUnlocked"), object: nil)
                XCTAssertFalse(approvals.timedAllowanceSessionSleeping)
                XCTAssertNil(approvals.timedAllowanceSleepOffsetAtSleep)
                let fresh = try submit(approvals, credential: "fresh")
                XCTAssertEqual(try vault.decideAgentApproval(requestID: fresh.requestID, capability: fresh.capability,
                    decision: .timedAllow(duration: 120)).state, .approved)
                let generation = approvals.timedAllowanceSessionGeneration
                screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
                XCTAssertEqual(approvals.timedAllowanceSessionGeneration, generation)
                XCTAssertEqual(try approvals.status(requestID: fresh.requestID, capability: fresh.capability), .approved)
                workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
                XCTAssertTrue(approvals.timedAllowanceSessionSleeping)
                XCTAssertEqual(approvals.timedAllowanceSleepOffsetAtSleep, 101, "A new willSleep starts a new interval")
            }
        }
    }

    func testLiveUnlockedCannotOverrideInactiveSessionUntilBecomeActive() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        let approvals = vault.approvalRequests
        approvals.configureTimedAllowanceScreenState { true }
        approvals.configureAuthentication { _ in true }
        let workspace = TimedAllowanceTestNotificationCenter()
        let observer = SynchronousTimedAllowanceSessionObserver(screenNotifications: .init(), workspaceNotifications: workspace,
            screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3, sleepOffsetUpperBound: $4) })
        defer { withExtendedLifetime(observer) {} }
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        let pending = try submit(approvals, credential: "inactive-session")
        XCTAssertThrowsError(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)))
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)).state, .approved)
    }

    func testSettingOffWillSleepAndDidWakeNeverReadLiveProviderOrRevoke() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        let approvals = vault.approvalRequests
        let probe = ScreenProbe(.locked)
        approvals.configureTimedAllowanceScreenState { probe.unlocked() }
        approvals.configureTimedAllowanceSleepOffset { (100, 100) }
        approvals.configureAuthentication { _ in true }
        let workspace = TimedAllowanceTestNotificationCenter()
        let observer = SynchronousTimedAllowanceSessionObserver(screenNotifications: .init(), workspaceNotifications: workspace,
            screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3, sleepOffsetUpperBound: $4) })
        defer { withExtendedLifetime(observer) {} }
        let ticket = try submit(approvals, credential: "timed")
        _ = try vault.decideAgentApproval(requestID: ticket.requestID, capability: ticket.capability,
            decision: .timedAllow(duration: 120))
        let deadline = try XCTUnwrap(approvals.timedAllowanceDeadline(credentialID: "timed"))
        let generation = approvals.timedAllowanceSessionGeneration
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            workspace.post(name: event, object: nil)
            XCTAssertEqual(approvals.timedAllowanceDeadline(credentialID: "timed"), deadline)
            XCTAssertEqual(try approvals.status(requestID: ticket.requestID, capability: ticket.capability), .approved)
            XCTAssertEqual(approvals.timedAllowanceSessionGeneration, generation)
            XCTAssertEqual(probe.reads, 0, "Setting-off sleep and wake must not consult the live provider")
        }
    }

    func testEnablingBetweenWillSleepAndActualSleepRevokesButProvenMissedWakePreservesAllowance() throws {
        for liveProvider in [false, true] {
            for provenSleep in [false, true] {
                let library = try AgentAccessPolicyTestLibrary()
                defer { try? library.close() }
                let vault = library.vault
                let approvals = vault.approvalRequests
                let offset = SleepOffsetProbe()
                approvals.configureTimedAllowanceSleepOffset { offset.current }
                if liveProvider { approvals.configureTimedAllowanceScreenState { true } }
                approvals.configureAuthentication { _ in true }
                let screen = TimedAllowanceTestNotificationCenter()
                let workspace = TimedAllowanceTestNotificationCenter()
                let observer = SynchronousTimedAllowanceSessionObserver(screenNotifications: screen, workspaceNotifications: workspace,
                    screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3, sleepOffsetUpperBound: $4) })
                defer { withExtendedLifetime(observer) {} }
                let previous = try submit(approvals, credential: "previous")
                _ = try vault.decideAgentApproval(requestID: previous.requestID, capability: previous.capability,
                    decision: .timedAllow(duration: 120))
                let deadline = try XCTUnwrap(approvals.timedAllowanceDeadline(credentialID: "previous"))
                workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
                XCTAssertEqual(try approvals.status(requestID: previous.requestID, capability: previous.capability), .approved)
                if provenSleep {
                    offset.set(lower: 101, upper: 101)
                    if !liveProvider { screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil) }
                }
                let generation = approvals.timedAllowanceSessionGeneration
                try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
                XCTAssertEqual(approvals.timedAllowanceSessionSleeping, !provenSleep)
                XCTAssertEqual(approvals.timedAllowanceSessionGeneration == generation, provenSleep)
                XCTAssertEqual(approvals.timedAllowanceDeadline(credentialID: "previous"), provenSleep ? deadline : nil)
                XCTAssertEqual(try approvals.status(requestID: previous.requestID, capability: previous.capability),
                    provenSleep ? .approved : .cancelled)
                let fresh = try submit(approvals, credential: "fresh")
                let decide = {
                    try vault.decideAgentApproval(requestID: fresh.requestID, capability: fresh.capability,
                        decision: .timedAllow(duration: 120))
                }
                if provenSleep {
                    XCTAssertEqual(try decide().state, .approved)
                } else {
                    XCTAssertThrowsError(try decide()) { XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision) }
                    XCTAssertEqual(try approvals.status(requestID: fresh.requestID, capability: fresh.capability), .pending)
                    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
                    XCTAssertEqual(try decide().state, .approved)
                    XCTAssertEqual(try approvals.status(requestID: previous.requestID, capability: previous.capability), .cancelled)
                }
            }
        }
    }

    func testFullLockUnlockCycleBeforeProvenSleepKeepsSleepingSet() throws {
        for liveProvider in [false, true] {
            let library = try AgentAccessPolicyTestLibrary()
            defer { try? library.close() }
            let vault = library.vault
            try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
            let approvals = vault.approvalRequests
            approvals.configureTimedAllowanceSleepOffset { (100, 100) }
            if liveProvider { approvals.configureTimedAllowanceScreenState { true } }
            approvals.configureAuthentication { _ in true }
            let screen = TimedAllowanceTestNotificationCenter()
            let workspace = TimedAllowanceTestNotificationCenter()
            let observer = SynchronousTimedAllowanceSessionObserver(screenNotifications: screen, workspaceNotifications: workspace,
                screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3, sleepOffsetUpperBound: $4) })
            defer { withExtendedLifetime(observer) {} }
            workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
            screen.post(name: .init("com.apple.screenIsLocked"), object: nil)
            screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
            XCTAssertTrue(approvals.timedAllowanceSessionSleeping)
            XCTAssertEqual(approvals.timedAllowanceSleepOffsetAtSleep, 100)
            let pending = try submit(approvals, credential: "pending")
            XCTAssertThrowsError(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
                decision: .timedAllow(duration: 120))) { XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision) }
            XCTAssertTrue(approvals.timedAllowanceSessionSleeping)
            XCTAssertEqual(try approvals.status(requestID: pending.requestID, capability: pending.capability), .pending)
            workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
            XCTAssertEqual(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
                decision: .timedAllow(duration: 120)).state, .approved)
        }
    }

    func testResignWillSleepDidWakeKeepsGrantsBlockedUntilBecomeActive() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        let approvals = vault.approvalRequests
        approvals.configureTimedAllowanceScreenState { true }
        approvals.configureTimedAllowanceSleepOffset { (100, 100) }
        approvals.configureAuthentication { _ in true }
        let workspace = TimedAllowanceTestNotificationCenter()
        let observer = SynchronousTimedAllowanceSessionObserver(screenNotifications: .init(), workspaceNotifications: workspace,
            screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3, sleepOffsetUpperBound: $4) })
        defer { withExtendedLifetime(observer) {} }
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertFalse(approvals.timedAllowanceSessionSleeping)
        XCTAssertTrue(approvals.timedAllowanceSessionSuspended)
        let pending = try submit(approvals, credential: "pending")
        XCTAssertThrowsError(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120))) { XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision) }
        XCTAssertEqual(try approvals.status(requestID: pending.requestID, capability: pending.capability), .pending)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)).state, .approved)
    }

    private func submit(_ approvals: BrokerApprovalStateMachine, credential: String,
                        operation: BrokerApprovalOperation = .read) throws -> BrokerApprovalTicket {
        try approvals.submit(.init(operationID: UUID().uuidString, credentialID: credential, targetID: credential,
            operation: operation, payloadDigest: String(repeating: "a", count: 64)), trustedCredentialDeadline: .none)
    }
}

private final class ScreenProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var state: AgentApprovalScreenState
    private var count = 0
    init(_ state: AgentApprovalScreenState) { self.state = state }
    var current: AgentApprovalScreenState { lock.lock(); defer { lock.unlock() }; return state }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    func set(_ state: AgentApprovalScreenState) { lock.lock(); defer { lock.unlock() }; self.state = state }
    func unlocked() -> Bool { lock.lock(); defer { lock.unlock() }; count += 1; return state == .unlocked }
}

private final class SleepOffsetProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var bounds: (lower: UInt64, upper: UInt64) = (100, 100)
    var current: (lower: UInt64, upper: UInt64) { lock.lock(); defer { lock.unlock() }; return bounds }
    func set(lower: UInt64, upper: UInt64) { lock.lock(); defer { lock.unlock() }; bounds = (lower, upper) }
}
