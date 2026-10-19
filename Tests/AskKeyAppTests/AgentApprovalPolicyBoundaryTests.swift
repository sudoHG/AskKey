import Foundation
import XCTest

final class AgentApprovalPolicyBoundaryTests: XCTestCase {
    func testAppApprovalDecisionsCannotBypassVaultPolicyBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appendingPathComponent("Sources/AskKeyAppKit")
        let bypass = try NSRegularExpression(pattern: #"approvalRequests\s*\.\s*decide\s*\("#)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.allObjects as? [URL])
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(bypass.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), file.lastPathComponent)
        }
        for path in ["App/AppDelegate+Approval.swift", "VaultViewModel+PendingApprovals.swift"] {
            let source = try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("Vault.shared.decideAgentApproval("), path)
        }
    }
}
