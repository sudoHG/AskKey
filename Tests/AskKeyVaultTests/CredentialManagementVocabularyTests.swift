import CryptoKit
import Darwin
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class CredentialManagementVocabularyTests: HumanFileCredentialTestSupport {
    func testManagementCopyKeepsFileVocabularyOnExistingScreens() throws {
        XCTAssertEqual(CredentialManagementCopy.file, "File")
        XCTAssertEqual(CredentialManagementCopy.text, "Text")
        XCTAssertEqual(CredentialManagementCopy.originalFilename, "Original filename")
        XCTAssertEqual(CredentialManagementCopy.fileSize, "Size")
        XCTAssertEqual(CredentialManagementCopy.contentDigest, "Digest")
        XCTAssertEqual(CredentialManagementCopy.chooseFile, "Choose file")
        XCTAssertEqual(CredentialManagementCopy.replaceFile, "Replace file")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for relative in ["Sources/AskKeyAppKit/Views/CredentialManagementView.swift"] {
            let viewSource = try CredentialManagementSource.read(from: root, relative: relative)
            XCTAssertTrue(
                viewSource.contains("CredentialManagementCopy.file") || viewSource.contains("\"文件\""),
                "\(relative) should surface the frozen file label"
            )
            XCTAssertTrue(viewSource.contains("Choose file") || viewSource.contains("CredentialManagementCopy.chooseFile") || viewSource.contains("payloadKind"), "\(relative) should surface file credentials")
            XCTAssertFalse(viewSource.contains("Project"), "\(relative) still names Project")
            XCTAssertFalse(viewSource.contains("Environments"), "\(relative) still names Environments")
            XCTAssertFalse(viewSource.localizedCaseInsensitiveContains("strict"), "\(relative) still names strict")
        }
    }
}
