import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyCore

final class OfficialInstallTopologyTests: XCTestCase {
    private let canonicalApp = URL(fileURLWithPath: "/Applications/Ask Key.app", isDirectory: true)
    private let canonicalHelper = URL(
        fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"
    )

    func testCanonicalPathsStayOnTheDocumentedApplicationsContract() {
        XCTAssertEqual(OfficialInstallTopology.canonicalAppPath, "/Applications/Ask Key.app")
        XCTAssertEqual(
            OfficialInstallTopology.canonicalHelperPath,
            "/Applications/Ask Key.app/Contents/Helpers/askkey"
        )
        XCTAssertEqual(CodexUserMCP.bundledHelperPath, OfficialInstallTopology.canonicalHelperPath)
    }

    func testOfficialBundleAtApplicationsIsAccepted() {
        XCTAssertEqual(
            OfficialInstallTopology.decide(
                bundleURL: canonicalApp,
                isDevelopmentBuild: false
            ),
            .accepted(helperURL: canonicalHelper)
        )
        XCTAssertTrue(
            OfficialInstallTopology.allowsOfficialRuntime(
                OfficialInstallTopology.decide(
                    bundleURL: canonicalApp,
                    isDevelopmentBuild: false
                )
            )
        )
        XCTAssertEqual(
            try OfficialInstallTopology.resolvedHelperURL(
                bundleURL: canonicalApp,
                isDevelopmentBuild: false
            ),
            canonicalHelper
        )
    }

    func testMovedOfficialBundleFailsClosedWithRepairGuidance() {
        let moved = URL(fileURLWithPath: "/tmp/askkey-scratch/Ask Key.app", isDirectory: true)
        let decision = OfficialInstallTopology.decide(
            bundleURL: moved,
            isDevelopmentBuild: false
        )
        XCTAssertEqual(decision, .relocatedOrRenamed)
        XCTAssertFalse(OfficialInstallTopology.allowsOfficialRuntime(decision))
        XCTAssertTrue(
            OfficialInstallTopology.nextStep(for: decision).contains("/Applications/Ask Key.app")
        )
        XCTAssertThrowsError(
            try OfficialInstallTopology.resolvedHelperURL(
                bundleURL: moved,
                isDevelopmentBuild: false
            )
        ) { error in
            guard case OfficialInstallTopologyError.unavailable(.relocatedOrRenamed) = error else {
                return XCTFail("expected relocated failure, got \(error)")
            }
        }
    }

    func testRenamedOfficialBundleFailsClosed() {
        let renamed = URL(fileURLWithPath: "/Applications/AskKey.app", isDirectory: true)
        XCTAssertEqual(
            OfficialInstallTopology.decide(
                bundleURL: renamed,
                isDevelopmentBuild: false
            ),
            .relocatedOrRenamed
        )
    }

    func testMismatchedHelperFailsClosedWithoutCallingItAForeignHelper() {
        let foreignHelper = URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/MacOS/askkey")
        let decision = OfficialInstallTopology.decide(
            bundleURL: canonicalApp,
            helperURL: foreignHelper,
            isDevelopmentBuild: false
        )
        XCTAssertEqual(decision, .helperMismatch)
        XCTAssertFalse(OfficialInstallTopology.allowsOfficialRuntime(decision))
        let guidance = OfficialInstallTopology.nextStep(for: decision)
        XCTAssertTrue(guidance.localizedCaseInsensitiveContains("helper"))
        XCTAssertFalse(guidance.localizedCaseInsensitiveContains("foreign"))
        XCTAssertFalse(guidance.localizedCaseInsensitiveContains("untrusted"))
    }

    func testDevelopmentIsolationAcceptsANonApplicationsBundle() throws {
        let isolated = URL(
            fileURLWithPath: "/tmp/331-381-derived/AskKeyApp.app",
            isDirectory: true
        )
        let helper = isolated.appendingPathComponent("Contents/Helpers/askkey")
        let decision = OfficialInstallTopology.decide(
            bundleURL: isolated,
            isDevelopmentBuild: true
        )
        XCTAssertEqual(decision, .developmentAccepted(helperURL: helper))
        XCTAssertTrue(OfficialInstallTopology.allowsOfficialRuntime(decision))
        XCTAssertEqual(
            try OfficialInstallTopology.resolvedHelperURL(
                bundleURL: isolated,
                isDevelopmentBuild: true
            ),
            helper
        )
        XCTAssertNotEqual(helper.path, OfficialInstallTopology.canonicalHelperPath)
    }

    func testDevelopmentStillRejectsAHelperOutsideItsBundle() {
        let isolated = URL(
            fileURLWithPath: "/tmp/331-381-derived/AskKeyApp.app",
            isDirectory: true
        )
        XCTAssertEqual(
            OfficialInstallTopology.decide(
                bundleURL: isolated,
                helperURL: URL(fileURLWithPath: "/tmp/other/askkey"),
                isDevelopmentBuild: true
            ),
            .helperMismatch
        )
    }
}
