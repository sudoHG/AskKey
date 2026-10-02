import XCTest
@testable import AskKeyCore

final class SecretReferenceTests: XCTestCase {
    // MARK: - Parsing: the three forms

    func testParsesKeyOnlyForm() throws {
        let ref = try SecretReference(parsing: "askkey://GITHUB_TOKEN")
        XCTAssertNil(ref.projectName)
        XCTAssertNil(ref.environmentName)
        XCTAssertEqual(ref.key, "GITHUB_TOKEN")
        XCTAssertEqual(ref.text, "askkey://GITHUB_TOKEN")
    }

    func testParsesProjectKeyForm() throws {
        let ref = try SecretReference(parsing: "askkey://myproject/GITHUB_TOKEN")
        XCTAssertEqual(ref.projectName, "myproject")
        XCTAssertNil(ref.environmentName)
        XCTAssertEqual(ref.key, "GITHUB_TOKEN")
    }

    func testParsesProjectEnvKeyForm() throws {
        let ref = try SecretReference(parsing: "askkey://myproject/staging/GITHUB_TOKEN")
        XCTAssertEqual(ref.projectName, "myproject")
        XCTAssertEqual(ref.environmentName, "staging")
        XCTAssertEqual(ref.key, "GITHUB_TOKEN")
    }

    // MARK: - Malformed references

    func testEmptyReferenceIsMalformed() {
        XCTAssertThrowsError(try SecretReference(parsing: "askkey://")) { error in
            XCTAssertEqual(error as? SecretReference.ParseError, .emptySegment)
        }
    }

    func testEmptyLeadingSegmentIsMalformed() {
        XCTAssertThrowsError(try SecretReference(parsing: "askkey:///KEY")) { error in
            XCTAssertEqual(error as? SecretReference.ParseError, .emptySegment)
        }
    }

    func testEmptyMiddleSegmentIsMalformed() {
        XCTAssertThrowsError(try SecretReference(parsing: "askkey://proj//KEY")) { error in
            XCTAssertEqual(error as? SecretReference.ParseError, .emptySegment)
        }
    }

    func testTrailingSlashIsMalformed() {
        XCTAssertThrowsError(try SecretReference(parsing: "askkey://proj/KEY/")) { error in
            XCTAssertEqual(error as? SecretReference.ParseError, .emptySegment)
        }
    }

    func testTooManySegmentsIsMalformed() {
        XCTAssertThrowsError(try SecretReference(parsing: "askkey://a/b/c/d")) { error in
            XCTAssertEqual(error as? SecretReference.ParseError, .tooManySegments)
        }
    }

    func testNonReferenceStringThrowsNotAReference() {
        XCTAssertThrowsError(try SecretReference(parsing: "sk-plain-value")) { error in
            XCTAssertEqual(error as? SecretReference.ParseError, .notAReference)
        }
    }

    // MARK: - Non-ref predicate

    func testIsReferencePredicate() {
        XCTAssertTrue(SecretReference.isReference("askkey://KEY"))
        XCTAssertTrue(SecretReference.isReference("askkey://proj/env/KEY"))
        XCTAssertTrue(SecretReference.isReference("askkey://"))  // a ref, just malformed
        XCTAssertFalse(SecretReference.isReference("sk-abc123"))
        XCTAssertFalse(SecretReference.isReference("https://example.com"))
        XCTAssertFalse(SecretReference.isReference(""))
        // Only a prefix counts — an embedded occurrence is not a reference.
        XCTAssertFalse(SecretReference.isReference("see askkey://KEY"))
    }

    // MARK: - Scan

    func testScanFindsOnlyReferencesSortedByVariable() throws {
        let environment = [
            "PATH": "/usr/bin",
            "Z_TOKEN": "askkey://proj/Z",
            "A_TOKEN": "askkey://A",
            "HOME": "/Users/me",
        ]
        let refs = try SecretReference.scan(environment)
        XCTAssertEqual(refs.map(\.variable), ["A_TOKEN", "Z_TOKEN"])
        XCTAssertEqual(refs[0].reference.key, "A")
        XCTAssertEqual(refs[1].reference.projectName, "proj")
        XCTAssertEqual(refs[1].reference.key, "Z")
    }

    func testScanThrowsNamingVariableOnMalformedReference() {
        let environment = ["BAD_REF": "askkey://a/b/c/d"]
        XCTAssertThrowsError(try SecretReference.scan(environment)) { error in
            guard let substitutionError = error as? SecretReferenceSubstitutionError else {
                return XCTFail("Expected SecretReferenceSubstitutionError, got \(error)")
            }
            XCTAssertEqual(substitutionError.variable, "BAD_REF")
            XCTAssertEqual(substitutionError.reference, "askkey://a/b/c/d")
        }
    }

    // MARK: - Substitution

    func testSubstituteReplacesRefsAndLeavesNonRefsUntouched() throws {
        let environment = [
            "PATH": "/usr/bin:/bin",
            "GITHUB_TOKEN": "askkey://myproject/GITHUB_TOKEN",
            "OPENAI_API_KEY": "askkey://OPENAI_API_KEY",
            "PLAIN": "not-a-ref askkey:// inside",
        ]
        let result = try SecretReference.substitute(in: environment) { ref in
            "resolved(\(ref.projectName ?? "-")/\(ref.key))"
        }
        XCTAssertEqual(result["GITHUB_TOKEN"], "resolved(myproject/GITHUB_TOKEN)")
        XCTAssertEqual(result["OPENAI_API_KEY"], "resolved(-/OPENAI_API_KEY)")
        // Non-ref values are inherited byte-for-byte.
        XCTAssertEqual(result["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(result["PLAIN"], "not-a-ref askkey:// inside")
        XCTAssertEqual(result.count, environment.count)
    }

    func testSubstituteWithoutRefsReturnsEnvironmentUnchanged() throws {
        let environment = ["PATH": "/usr/bin", "USER": "me"]
        let result = try SecretReference.substitute(in: environment) { _ in
            XCTFail("Resolver must not be called when there are no references")
            return ""
        }
        XCTAssertEqual(result, environment)
    }

    func testSubstituteWrapsResolverErrorWithVariableAndReference() {
        struct NotFound: LocalizedError {
            var errorDescription: String? { "Secret 'MISSING' not found." }
        }
        let environment = ["MY_VAR": "askkey://proj/MISSING"]
        XCTAssertThrowsError(try SecretReference.substitute(in: environment) { _ in
            throw NotFound()
        }) { error in
            guard let substitutionError = error as? SecretReferenceSubstitutionError else {
                return XCTFail("Expected SecretReferenceSubstitutionError, got \(error)")
            }
            XCTAssertEqual(substitutionError.variable, "MY_VAR")
            XCTAssertEqual(substitutionError.reference, "askkey://proj/MISSING")
            XCTAssertEqual(substitutionError.reason, "Secret 'MISSING' not found.")
            // The printed message names the variable and the ref text.
            let message = substitutionError.localizedDescription
            XCTAssertTrue(message.contains("MY_VAR"))
            XCTAssertTrue(message.contains("askkey://proj/MISSING"))
        }
    }

    func testSubstituteFailsClosedOnMalformedWithoutCallingResolver() {
        let environment = [
            "GOOD": "askkey://proj/KEY",
            "BAD": "askkey:///KEY",
        ]
        XCTAssertThrowsError(try SecretReference.substitute(in: environment) { _ in
            XCTFail("Resolver must not be called when any reference is malformed")
            return "leaked"
        }) { error in
            guard let substitutionError = error as? SecretReferenceSubstitutionError else {
                return XCTFail("Expected SecretReferenceSubstitutionError, got \(error)")
            }
            XCTAssertEqual(substitutionError.variable, "BAD")
        }
    }
}
