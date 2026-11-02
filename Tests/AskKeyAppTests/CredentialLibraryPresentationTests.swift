import XCTest
import AskKeyBroker
import AskKeyVault
@testable import AskKeyAppKit

@MainActor
final class CredentialLibraryPresentationTests: AskKeyAppTestCase {
    func testSearchAndGroupFiltersKeepAllActiveGrantsEvenWithoutMatchingCredentials() {
        let credentials = [credential("alpha", group: "Project"), credential("other", group: "Other")]
        let allowances = [BrokerTimedAllowance(groupName: "Project", members: [
            .init(credentialID: "alpha", name: "Alpha", metadataDigest: String(repeating: "a", count: 64))
        ], expiresAt: Date().addingTimeInterval(1_800))]
        for (section, query, expected) in [
            (CredentialWorkspaceSection.all, "", ["alpha", "other"]),
            (.all, "other", ["other"]),
            (.all, "no match", []),
            (.named("Other"), "", ["other"]),
            (.named("Empty"), "", []),
            (.ungrouped, "", [])
        ] {
            let presentation = CredentialLibraryPresentation(credentials: credentials, allowances: allowances,
                                                              section: section, searchText: query)
            XCTAssertEqual(presentation.credentials.map(\.id), expected)
            XCTAssertEqual(presentation.allowances, allowances, "Filters must preserve the grant and its revocation target")
        }
    }

    private func credential(_ name: String, group: String) -> ManagedTextCredential {
        .init(id: name, name: name, value: nil, usageInstructions: "", privateNotes: nil,
              groupName: group, environmentVariable: nil, permission: .ask, expiresAt: nil,
              payloadKind: .text, originalFilename: nil, byteSize: nil, contentDigest: nil, fileBytes: nil, components: [])
    }
}
