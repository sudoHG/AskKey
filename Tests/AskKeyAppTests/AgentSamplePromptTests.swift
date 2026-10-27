import Foundation
import XCTest
import AskKeyVault
@testable import AskKeyAppKit

@MainActor
final class AgentSamplePromptTests: AskKeyAppTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEmptyLibraryHasNoSample() {
        XCTAssertNil(sample([]))
    }

    func testAllUndeliveredAndComponentlessCredentialsHaveNoSample() {
        XCTAssertNil(sample([credential(deliveries: [.none, .none])]))
        XCTAssertNil(sample([credential(deliveries: [])]))
    }

    func testHiddenCredentialHasNoSampleEvenWithDeliverableComponents() {
        XCTAssertNil(sample([credential(permission: .hidden)]))
    }

    func testExpiredCredentialHasNoSampleIncludingExactDeadline() {
        XCTAssertNil(sample([credential(expiresAt: now.addingTimeInterval(-1))]))
        XCTAssertNil(sample([credential(expiresAt: now)]))
        XCTAssertEqual(sample([credential(expiresAt: now.addingTimeInterval(1))]), "Synthetic API")
    }

    func testDeletedCredentialHasNoSample() {
        XCTAssertNil(sample([credential(deletedAt: now.addingTimeInterval(-1))]))
    }

    func testAskAndAllowAcceptAtLeastOneDeliverableComponent() {
        XCTAssertEqual(sample([credential(deliveries: [.none, .environmentVariable("SYNTHETIC_TOKEN")])]),
                       "Synthetic API")
        XCTAssertEqual(sample([credential(permission: .allowed, deliveries: [.temporaryFile("SYNTHETIC_FILE")])]),
                       "Synthetic API")
    }

    func testSingleTextWithMappingHasSample() {
        XCTAssertEqual(sample([credential(deliveries: [], kind: .text, mapping: "SYNTHETIC_TOKEN")]), "Synthetic API")
    }

    func testSingleTextWithoutMappingHasNoSample() {
        XCTAssertNil(sample([credential(deliveries: [], kind: .text)]))
    }

    func testSingleFileWithMappingHasSample() {
        XCTAssertEqual(sample([credential(deliveries: [], kind: .file, mapping: "SYNTHETIC_FILE")]), "Synthetic API")
    }

    func testSingleFileWithoutMappingHasNoSample() {
        XCTAssertNil(sample([credential(deliveries: [], kind: .file)]))
    }

    func testSingleMetadataProjectionsUseComponentDeliveryWhenPopulated() {
        for kind in [CredentialPayloadKind.text, .file] {
            let delivery: CredentialComponentDelivery = kind == .file
                ? .temporaryFile("SYNTHETIC_FILE") : .environmentVariable("SYNTHETIC_TOKEN")
            XCTAssertEqual(sample([credential(deliveries: [delivery], kind: kind)]), "Synthetic API")
            XCTAssertNil(sample([credential(deliveries: [.none], kind: kind)]))
        }
    }

    func testFirstDeliverableNameUsesNaturalSortAfterExcludingUnavailableCredentials() {
        let credentials = [
            credential(name: "API 10"), credential(name: "API 2"),
            credential(name: "API 0", deliveries: [.none]),
            credential(name: "API 1", permission: .hidden),
            credential(name: "API 1 expired", expiresAt: now),
            credential(name: "API 1 deleted", deletedAt: now),
        ]
        XCTAssertEqual(sample(credentials), "API 2")
    }

    private func sample(_ credentials: [ManagedTextCredential]) -> String? {
        AgentOnboardingCopy.sampleCredentialName(in: credentials, now: now)
    }

    private func credential(
        name: String = "Synthetic API", permission: CredentialPermission = .ask,
        expiresAt: Date? = nil, deletedAt: Date? = nil,
        deliveries: [CredentialComponentDelivery] = [.environmentVariable("SYNTHETIC_TOKEN")],
        kind: CredentialPayloadKind = .bundle, mapping: String? = nil
    ) -> ManagedTextCredential {
        ManagedTextCredential(
            id: name, name: name, value: nil, usageInstructions: "", privateNotes: nil,
            groupName: nil, environmentVariable: mapping, permission: permission, expiresAt: expiresAt,
            payloadKind: kind, originalFilename: nil, byteSize: nil, contentDigest: nil, fileBytes: nil,
            components: deliveries.enumerated().map {
                .init(name: "SYNTHETIC_\($0.offset)", kind: kind == .file ? .file : .text,
                      value: nil, delivery: $0.element)
            }, deletedAt: deletedAt
        )
    }
}
