import Darwin
import Foundation
import XCTest
@testable import AskKeyAppKit
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeyVault
@testable import AskKeyTestSupport

@MainActor
final class CredentialEditorComponentTests: AgentClientConnectorTestSupport {
    func testBundleEditorNeverOffersTheLegacyGlobalEnvironmentVariable() {
        XCTAssertFalse(
            CredentialEditorPresentation.showsGlobalEnvironmentVariable(
                editingExisting: false,
                payloadKind: .text
            )
        )
        XCTAssertFalse(
            CredentialEditorPresentation.showsGlobalEnvironmentVariable(
                editingExisting: true,
                payloadKind: .bundle
            )
        )
        XCTAssertTrue(
            CredentialEditorPresentation.showsGlobalEnvironmentVariable(
                editingExisting: true,
                payloadKind: .text
            )
        )
    }

    func testBundleEditorRejectsTheWholePersistedBundleWhenAFileComponentIsInvalid() {
        let components = [
            ManagedCredentialComponent(name: "USERNAME", value: .text("agent")),
            ManagedCredentialComponent(name: "CERTIFICATE", value: .file(filename: "", bytes: Data("x".utf8)))
        ]

        XCTAssertThrowsError(try CredentialEditorComponentLoader.load(components))
    }

    func testBundleEditorRejectsHalfFilledOptionalComponents() {
        let complete = CredentialComponentDraft(name: "PRIMARY", text: "value")

        XCTAssertTrue(CredentialEditorComponentValidation.canSave([complete]))
        XCTAssertTrue(CredentialEditorComponentValidation.canSave([
            complete,
            CredentialComponentDraft(isOptional: true),
        ]))
        XCTAssertFalse(CredentialEditorComponentValidation.canSave([
            complete,
            CredentialComponentDraft(name: "SECONDARY", isOptional: true),
        ]))
        XCTAssertNil(CredentialEditorComponentValidation.inputs([
            complete,
            CredentialComponentDraft(name: "SECONDARY", isOptional: true),
        ]))
        XCTAssertFalse(CredentialEditorComponentValidation.canSave([
            complete,
            CredentialComponentDraft(text: "orphan-value", isOptional: true),
        ]))
    }

    func testAPITemplateCanSaveWithAnEmptyEndpoint() throws {
        var components = CredentialTemplate.api.components
        guard let keyIndex = components.firstIndex(where: { $0.name == "API_KEY" }) else {
            return XCTFail("API template must include API_KEY")
        }
        components[keyIndex].text = "secret-key"

        XCTAssertTrue(CredentialEditorComponentValidation.canSave(components))
        let inputs = try XCTUnwrap(CredentialEditorComponentValidation.inputs(components))
        XCTAssertEqual(inputs.map(\.name), ["API_KEY"])

        guard let endpointIndex = components.firstIndex(where: { $0.name == "API_ENDPOINT" }) else {
            return XCTFail("API template must include API_ENDPOINT")
        }
        components[endpointIndex].name = "CUSTOM_SECRET"
        XCTAssertFalse(CredentialEditorComponentValidation.canSave(components))
        XCTAssertNil(CredentialEditorComponentValidation.inputs(components))
    }
}
