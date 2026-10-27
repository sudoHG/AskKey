import XCTest
@testable import AskKeyBroker

final class FileWriteFilenameValidationTests: FileWriteCoordinatorTestCase {
    func testOversizedFilenameIsInvalidBeforeUploadOrApprovalForCreateAndModify() throws {
        for operation in [BrokerApprovalOperation.create, .modify] {
            for count in [255, 256, 4096] {
                let harness = try makeHarness()
                let before = try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).sorted()
                let filename = String(repeating: "F", count: count)
                if count == 255 {
                    XCTAssertNoThrow(try harness.coordinator.begin(operationID: "valid", credentialID: "credential-id", targetID: "credential-id",
                        operation: operation, originalFilename: filename, expectedByteCount: 0))
                } else {
                    XCTAssertThrowsError(try harness.coordinator.begin(operationID: "invalid", credentialID: "credential-id", targetID: "credential-id",
                        operation: operation, originalFilename: filename, expectedByteCount: 0)) {
                        XCTAssertEqual($0 as? BrokerFileWriteError, .invalidRequest)
                    }
                    XCTAssertTrue(harness.approvals.pendingRequests().isEmpty)
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).sorted(), before)
                }
            }
        }
    }
}
