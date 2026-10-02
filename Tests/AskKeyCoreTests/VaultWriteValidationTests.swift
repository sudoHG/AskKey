import XCTest
@testable import AskKeyCore

/// Covers the write-path correctness fixes from the 2026-07-03 adversarial audit:
/// secret-name validation (M5).
final class VaultWriteValidationTests: XCTestCase {
    // MARK: - M5

    func testAddRejectsShellUnsafeSecretNames() throws {
        for bad in ["X'; rm -rf ~ #", "FOO BAR", "1FOO", "FOO-BAR", "FOO\nBAR", "", "a.b"] {
            XCTAssertThrowsError(try Vault.validateSecretName(bad), "name '\(bad)' should be rejected") { error in
                guard case VaultError.invalidSecretName = error else {
                    return XCTFail("expected invalidSecretName for '\(bad)', got \(error)")
                }
            }
        }
    }

    func testAddAcceptsValidIdentifierNames() throws {
        for good in ["FOO", "_FOO", "OPENAI_API_KEY", "a1_b2", "_"] {
            XCTAssertNoThrow(try Vault.validateSecretName(good), "name '\(good)' should be accepted")
        }
    }
}
