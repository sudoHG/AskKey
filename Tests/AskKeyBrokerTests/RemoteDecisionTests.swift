import XCTest
@testable import AskKeyBroker

/// What a remote decision may do to a pending request (ADR 0014 → Broker
/// remote path), with synthetic requests and approvers.
final class RemoteDecisionTests: RemoteApprovalTestCase {
    func testAllowOnceApprovesWithoutCallingTheLocalAuthentication() throws {
        let machine = configuredMachine(readAuthenticationEnabled: true, authenticate: { _ in
            XCTFail("A remote decision never calls the local authentication")
            return false
        })
        let operation = request(operationID: "allow-once")
        let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
        let approver = try activate(machine)
        XCTAssertEqual(try remote(machine, ticket, operation, approver, .allowOnce), .applied(.approved, grantedSeconds: 0))
        XCTAssertEqual(try state(machine, ticket), .approved)
        XCTAssertNil(machine.timedAllowanceDeadline(credentialID: "credential-1"), "Allow Once grants no allowance")
        let lease = try consumeForRuntime(machine, ticket, operation)
        XCTAssertEqual(lease.approvingDeviceNames, ["credential-1": "Synthetic Phone"])
        lease.finish()
    }

    func testDenyOnlyEverDenies() throws {
        let machine = configuredMachine(authenticate: { _ in XCTFail("Deny needs no authentication"); return false })
        let operation = request(operationID: "deny")
        let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
        let approver = try activate(machine)
        XCTAssertEqual(try remote(machine, ticket, operation, approver, .deny, ceiling: 60), .notApplicable)
        XCTAssertEqual(try state(machine, ticket), .pending, "A Deny with a duration is not as signed")
        XCTAssertEqual(try remote(machine, ticket, operation, approver, .deny), .applied(.denied, grantedSeconds: 0))
        XCTAssertEqual(try state(machine, ticket), .denied)
        XCTAssertTrue(machine.activeTimedAllowances().isEmpty)
        XCTAssertThrowsError(try machine.consumeForRuntime([
            .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: operation)
        ]))
    }

    func testWritesAndOrganizeOperationsAreRefusedAndStayPending() throws {
        let organize = BrokerApprovalOperationRequest(
            operationID: "organize", credentialID: "", targetID: "credential-library", operation: .organize,
            payloadDigest: String(repeating: "a", count: 64), organizationCredentialIDs: ["a", "b"])
        let writes = [BrokerApprovalOperation.create, .modify, .delete].map {
            request(operationID: "write-\($0.rawValue)", operation: $0)
        } + [organize]
        for operation in writes {
            let machine = configuredMachine(authenticate: { _ in true })
            let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
            let approver = try activate(machine)
            for (code, ceiling) in [(BrokerRemoteDecisionCode.deny, 0.0), (.allowOnce, 0), (.timedAllowance, 600)] {
                XCTAssertEqual(try remote(machine, ticket, operation, approver, code, ceiling: ceiling,
                                          revalidate: { XCTFail("Refused before policy I/O") }),
                               .notApplicable, "\(operation.operation) \(code)")
                XCTAssertEqual(try state(machine, ticket), .pending)
            }
            XCTAssertTrue(machine.activeTimedAllowances().isEmpty)
        }
    }

    func testTimedAllowanceNeverGrantsTheGroup() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        let digest = String(repeating: "b", count: 64)
        func read(_ id: String) -> BrokerApprovalOperationRequest {
            .init(operationID: "read-\(id)", credentialID: id, targetID: id, operation: .read,
                  payloadDigest: String(repeating: "a", count: 64), readProjectionDigest: digest)
        }
        let alpha = read("a")
        let ticket = try machine.submit(alpha, trustedCredentialDeadline: .none, groupAllowanceSnapshot: .init(
            groupName: "Project", members: [.init(credentialID: "a", name: "Alpha", metadataDigest: digest),
                                            .init(credentialID: "b", name: "Beta", metadataDigest: digest)]))
        let beta = try machine.submit(read("b"), trustedCredentialDeadline: .none)
        XCTAssertEqual(try remote(machine, ticket, alpha, try activate(machine), .timedAllowance, ceiling: 600),
                       .applied(.approved, grantedSeconds: 600))
        let allowances = machine.activeTimedAllowances()
        XCTAssertEqual(allowances.count, 1)
        XCTAssertNil(allowances.first?.groupName)
        XCTAssertEqual(allowances.first?.members.map(\.credentialID), ["a"])
        XCTAssertEqual(allowances.first?.approvingDeviceName, "Synthetic Phone")
        XCTAssertEqual(try state(machine, beta), .pending, "Other group members stay pending")
        XCTAssertNil(machine.timedAllowanceDeadline(credentialID: "b"))
    }

    func testTimedAllowanceIsRefusedWhileTimedAllowancesAreOff() throws {
        let machine = configuredMachine(timedAllowanceEnabled: false)
        let operation = request(operationID: "timed-off")
        let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
        XCTAssertEqual(try remote(machine, ticket, operation, try activate(machine), .timedAllowance, ceiling: 600),
                       .notApplicable)
        XCTAssertEqual(try state(machine, ticket), .pending)
        XCTAssertTrue(machine.activeTimedAllowances().isEmpty)
    }

    func testEndTimedAllowOnLockRefusesARemoteGrantOnTheSettingAloneWhileLocalGrantsStillWork() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
                                           timedAllowanceDuration: 30 * 60, endTimedAllowancesOnLock: true)
        machine.configureTimedAllowanceScreenState { true }
        machine.updateTimedAllowanceSession(active: true, endOnLock: true)
        let local = request(operationID: "local-timed", credentialID: "local")
        let localTicket = try machine.submit(local, trustedCredentialDeadline: .none)
        _ = try machine.decide(requestID: localTicket.requestID, capability: localTicket.capability,
                               decision: .timedAllow(duration: 600))
        XCTAssertNotNil(machine.timedAllowanceDeadline(credentialID: "local"), "The screen is unlocked")
        let operation = request(operationID: "remote-timed")
        let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
        let approver = try activate(machine)
        XCTAssertEqual(try remote(machine, ticket, operation, approver, .timedAllowance, ceiling: 600), .notApplicable)
        XCTAssertEqual(try state(machine, ticket), .pending)
        XCTAssertNil(machine.timedAllowanceDeadline(credentialID: "credential-1"))
        XCTAssertEqual(try remote(machine, ticket, operation, approver, .allowOnce), .applied(.approved, grantedSeconds: 0),
                       "Allow Once is still offered")
    }

    func testDurationIsTheShortestOfCeilingSettingAndCredentialDeadline() throws {
        let start = Date(timeIntervalSince1970: 20_000)
        let cases: [(ceiling: TimeInterval, deadline: Date?, granted: UInt64, end: Date)] = [
            (7_200, nil, 900, start.addingTimeInterval(900)),
            (600, nil, 600, start.addingTimeInterval(600)),
            (7_200, start.addingTimeInterval(100.5), 100, start.addingTimeInterval(100.5)),
        ]
        for item in cases {
            let machine = configuredMachine(defaultTimedAllowance: 15 * 60, clock: { start })
            let operation = request(operationID: "duration")
            let ticket = try machine.submit(operation, trustedCredentialDeadline: item.deadline.map(BrokerCredentialDeadline.expiresAt) ?? .none)
            XCTAssertEqual(try remote(machine, ticket, operation, try activate(machine), .timedAllowance, ceiling: item.ceiling),
                           .applied(.approved, grantedSeconds: item.granted))
            XCTAssertEqual(machine.timedAllowanceDeadline(credentialID: "credential-1"), item.end)
        }
    }

    func testSettingShortenedAfterSealingCapsTheGrant() throws {
        let start = Date(timeIntervalSince1970: 30_000)
        let machine = configuredMachine(defaultTimedAllowance: 30 * 60, clock: { start })
        let operation = request(operationID: "shortened")
        let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
        let approver = try activate(machine)
        // The request was sealed offering 30 minutes; the setting changes before the decision arrives.
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
                                           timedAllowanceDuration: 5 * 60)
        XCTAssertEqual(try remote(machine, ticket, operation, approver, .timedAllowance, ceiling: 30 * 60),
                       .applied(.approved, grantedSeconds: 300))
        XCTAssertEqual(machine.timedAllowanceDeadline(credentialID: "credential-1"), start.addingTimeInterval(300))
    }

    func testCeilingsThatAreNotAsSignedAreNotApplicable() throws {
        let machine = configuredMachine()
        let operation = request(operationID: "ceilings")
        let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
        let approver = try activate(machine)
        for ceiling in [0, -1, 7_201, .infinity, .nan] as [TimeInterval] {
            XCTAssertEqual(try remote(machine, ticket, operation, approver, .timedAllowance, ceiling: ceiling), .notApplicable)
        }
        XCTAssertEqual(try remote(machine, ticket, operation, approver, .allowOnce, ceiling: 60), .notApplicable)
        XCTAssertEqual(try state(machine, ticket), .pending)
        XCTAssertTrue(machine.activeTimedAllowances().isEmpty)
    }

    func testRemotelyGrantedAllowanceNamesTheDeviceForLaterReadsAndLocalGrantsNameNone() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        let first = request(operationID: "first")
        let ticket = try machine.submit(first, trustedCredentialDeadline: .none)
        _ = try remote(machine, ticket, first, try activate(machine), .timedAllowance, ceiling: 600)
        consumeForRuntime(machine, ticket, first, expecting: ["credential-1": "Synthetic Phone"])
        let later = request(operationID: "later")
        let laterTicket = try machine.submit(later, trustedCredentialDeadline: .none)
        XCTAssertEqual(laterTicket.state, .approved, "Covered by the remote allowance")
        consumeForRuntime(machine, laterTicket, later, expecting: ["credential-1": "Synthetic Phone"])

        let local = request(operationID: "local", credentialID: "local")
        let localTicket = try machine.submit(local, trustedCredentialDeadline: .none)
        _ = try machine.decide(requestID: localTicket.requestID, capability: localTicket.capability,
                               decision: .timedAllow(duration: 600))
        XCTAssertNil(machine.activeTimedAllowances().first { $0.members.first?.credentialID == "local" }?.approvingDeviceName)
        consumeForRuntime(machine, localTicket, local, expecting: [:])
    }

    func testRemoteDenialIsPublishedWithTheDeviceNameAndLocalDenialWithout() throws {
        let machine = configuredMachine()
        let names = LockedNames()
        machine.configureOperationStateChanged { _, _, state, device in
            if state == .denied { names.append(device) }
        }
        let remoteOperation = request(operationID: "remote-deny")
        let remoteTicket = try machine.submit(remoteOperation, trustedCredentialDeadline: .none)
        _ = try remote(machine, remoteTicket, remoteOperation, try activate(machine), .deny)
        let local = try machine.submit(request(operationID: "local-deny"), trustedCredentialDeadline: .none)
        _ = try machine.decide(requestID: local.requestID, capability: local.capability, decision: .deny)
        XCTAssertEqual(names.values, ["Synthetic Phone", nil])
    }

    func testMismatchedOperationAndUnknownRequestThrow() throws {
        let machine = configuredMachine()
        let operation = request(operationID: "bound")
        let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
        let approver = try activate(machine)
        XCTAssertThrowsError(try remote(machine, ticket, request(operationID: "bound", digest: String(repeating: "f", count: 64)),
                                        approver, .deny)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch)
        }
        let unknown = BrokerApprovalTicket(requestID: "unknown", capability: ticket.capability, state: .pending, retryCount: 0)
        XCTAssertThrowsError(try remote(machine, unknown, operation, approver, .deny)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .requestNotFound)
        }
        XCTAssertEqual(try state(machine, ticket), .pending)
    }

    private func consumeForRuntime(
        _ machine: BrokerApprovalStateMachine, _ ticket: BrokerApprovalTicket,
        _ operation: BrokerApprovalOperationRequest, expecting names: [String: String],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            let lease = try consumeForRuntime(machine, ticket, operation)
            XCTAssertEqual(lease.approvingDeviceNames, names, file: file, line: line)
            lease.finish()
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }
}

final class LockedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String?] = []

    func append(_ value: String?) { lock.lock(); stored.append(value); lock.unlock() }

    var values: [String?] { lock.lock(); defer { lock.unlock() }; return stored }
}
