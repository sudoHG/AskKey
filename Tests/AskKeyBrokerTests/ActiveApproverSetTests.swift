import XCTest
@testable import AskKeyBroker

/// The active-approver set's revocation counter and enablement generations
/// (ADR 0014 → Approvers). Synthetic pairing IDs.
final class ActiveApproverSetTests: RemoteApprovalTestCase {
    func testAdditionWithAStaleRevocationCountAddsNothing() throws {
        let machine = configuredMachine()
        let count = machine.activeApproverRevocationCount()
        // A revocation lands between reading the counter and reading the list.
        machine.removeActiveApprover(pairingID: tablet)
        XCTAssertThrowsError(try machine.addActiveApprovers([phone, tablet], revocationCount: count)) {
            XCTAssertEqual($0 as? BrokerActiveApproverError, .revocationRaced)
        }
        XCTAssertNil(machine.activeApproverGeneration(pairingID: phone))
        XCTAssertNil(machine.activeApproverGeneration(pairingID: tablet))
        try machine.addActiveApprovers([phone], revocationCount: machine.activeApproverRevocationCount())
        XCTAssertNotNil(machine.activeApproverGeneration(pairingID: phone))
    }

    func testEveryRemovalAndEmptyingCountsAsARevocation() throws {
        let machine = configuredMachine()
        let start = machine.activeApproverRevocationCount()
        try activate(machine)
        XCTAssertEqual(machine.activeApproverRevocationCount(), start, "Additions are not revocations")
        machine.removeActiveApprover(pairingID: phone)
        machine.removeActiveApprover(pairingID: phone)
        machine.removeAllActiveApprovers()
        XCTAssertEqual(machine.activeApproverRevocationCount(), start + 3)
    }

    func testEveryAdditionGetsANewGenerationAndOthersKeepTheirs() throws {
        let machine = configuredMachine()
        let first = try machine.addActiveApprovers([phone], revocationCount: machine.activeApproverRevocationCount())
        let phoneGeneration = try XCTUnwrap(first[phone])
        // After the tablet's flag write only the tablet is added; the phone keeps its generation.
        let tabletGeneration = try XCTUnwrap(try machine.addActiveApprovers(
            [tablet], revocationCount: machine.activeApproverRevocationCount())[tablet])
        XCTAssertGreaterThan(tabletGeneration, phoneGeneration)
        XCTAssertEqual(machine.activeApproverGeneration(pairingID: phone), phoneGeneration)
        // A reload adds every flagged entry again, each with a new generation.
        let reload = try machine.addActiveApprovers([phone, tablet], revocationCount: machine.activeApproverRevocationCount())
        XCTAssertGreaterThan(try XCTUnwrap(reload[phone]), tabletGeneration)
        XCTAssertGreaterThan(try XCTUnwrap(reload[tablet]), tabletGeneration)
        machine.removeActiveApprover(pairingID: phone)
        let again = try machine.addActiveApprovers([phone], revocationCount: machine.activeApproverRevocationCount())
        XCTAssertGreaterThan(try XCTUnwrap(again[phone]), try XCTUnwrap(reload[tablet]))
        machine.removeAllActiveApprovers()
        XCTAssertNil(machine.activeApproverGeneration(pairingID: phone))
        XCTAssertNil(machine.activeApproverGeneration(pairingID: tablet))
        let reloaded = try machine.addActiveApprovers([phone, tablet], revocationCount: machine.activeApproverRevocationCount())
        XCTAssertTrue(reloaded.values.allSatisfy { $0 > (again[phone] ?? .max) })
    }

    func testMalformedPairingIDsAreRefusedWhole() throws {
        let machine = configuredMachine()
        let count = machine.activeApproverRevocationCount()
        for ids in [[Data(count: 15)], [Data(count: 17)], [Data()], [phone, Data(count: 15)], [phone, phone]] {
            XCTAssertThrowsError(try machine.addActiveApprovers(ids, revocationCount: count)) {
                XCTAssertEqual($0 as? BrokerActiveApproverError, .malformedPairingID)
            }
        }
        XCTAssertNil(machine.activeApproverGeneration(pairingID: phone))
        XCTAssertEqual(machine.activeApproverRevocationCount(), count)
    }
}
