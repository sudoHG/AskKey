import XCTest
import AskKeyCore
@testable import AskKeyApp

final class ReviewEditorValidationTests: XCTestCase {
    func testBlankCustomRowsDoNotPreventSavingCompleteRows() throws {
        let complete = CredentialComponentDraft(name: "TOKEN", text: "value")
        for rows in [[CredentialComponentDraft(), complete], [complete, CredentialComponentDraft()], [complete, CredentialComponentDraft(kind: .file)]] {
            XCTAssertTrue(CredentialEditorComponentValidation.canSave(rows))
            XCTAssertEqual(CredentialEditorComponentValidation.inputs(rows)?.map(\.name), ["TOKEN"])
        }
        XCTAssertFalse(CredentialEditorComponentValidation.canSave([CredentialComponentDraft()]))
        XCTAssertFalse(CredentialEditorComponentValidation.canSave([complete, CredentialComponentDraft(name: "HALF")]))
    }

    func testEveryTemplateCanOmitItsPredefinedOptionalFields() throws {
        for template in CredentialTemplate.allCases where template != .custom {
            var rows = template.components
            for index in rows.indices where !rows[index].isOptional {
                if rows[index].kind == .file {
                    rows[index].file = try FileImport.FrozenFile(originalFilename: "synthetic.pem", bytes: Data("synthetic".utf8))
                } else { rows[index].text = "synthetic" }
            }
            XCTAssertTrue(CredentialEditorComponentValidation.canSave(rows), template.rawValue)
            let inputs = CredentialEditorComponentValidation.inputs(rows)
            XCTAssertNotNil(inputs, template.rawValue)
            XCTAssertEqual(inputs?.map(\.name), rows.filter { !$0.isOptional }.map(\.name), template.rawValue)
            for index in rows.indices where rows[index].isOptional {
                var renamed = rows
                renamed[index].name = "CUSTOM_REQUIRED"
                XCTAssertFalse(CredentialEditorComponentValidation.canSave(renamed), template.rawValue)
            }
        }
    }
}
