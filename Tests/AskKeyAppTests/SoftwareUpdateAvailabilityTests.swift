import Foundation
import XCTest
@testable import AskKeyAppKit
import AskKeyBroker

final class SoftwareUpdateAvailabilityTests: XCTestCase {
    private let officialHelper = URL(fileURLWithPath: OfficialInstallTopology.canonicalHelperPath)

    private var releaseInfo: [String: Any] {
        [
            "CFBundleIdentifier": "com.sudohg.askkey.app",
            "SUFeedURL": "https://askkey.sudohg.com/appcast.xml",
            "SUPublicEDKey": "synthetic-public-key",
        ]
    }

    func testOfficialReleaseInstallEnablesTheUpdater() {
        XCTAssertTrue(SoftwareUpdateAvailability.isEnabled(
            infoDictionary: releaseInfo, topology: .accepted(helperURL: officialHelper)
        ))
    }

    func testFeedURLIsTheProductIdentifier() {
        XCTAssertEqual(SoftwareUpdateAvailability.feedURL, "https://askkey.sudohg.com/appcast.xml")
    }

    func testMissingOrForeignFeedURLDisablesTheUpdater() {
        for feed in [nil, "", "https://example.com/appcast.xml", "http://askkey.sudohg.com/appcast.xml"] as [String?] {
            var info = releaseInfo
            info["SUFeedURL"] = feed
            XCTAssertFalse(
                SoftwareUpdateAvailability.isEnabled(infoDictionary: info, topology: .accepted(helperURL: officialHelper)),
                "feed \(feed ?? "nil")"
            )
        }
        var wrongType = releaseInfo
        wrongType["SUFeedURL"] = URL(string: SoftwareUpdateAvailability.feedURL)
        XCTAssertFalse(SoftwareUpdateAvailability.isEnabled(
            infoDictionary: wrongType, topology: .accepted(helperURL: officialHelper)
        ))
    }

    func testEveryTestingFlagDisablesTheUpdaterWhateverItsValue() {
        // The three flags build-app.sh writes, and any later AskKey-prefixed flag.
        let flags = ["AskKeyLocalTesting", "AskKeyE2ETesting", "AskKeyRequiresDebugRunDirectory", "AskKeyFutureTesting"]
        XCTAssertTrue(flags.allSatisfy { $0.hasPrefix(SoftwareUpdateAvailability.testingFlagPrefix) })
        for flag in flags {
            for value in [true, false] {
                var info = releaseInfo
                info[flag] = value
                XCTAssertFalse(
                    SoftwareUpdateAvailability.isEnabled(infoDictionary: info, topology: .accepted(helperURL: officialHelper)),
                    "\(flag) = \(value)"
                )
            }
        }
    }

    func testOnlyTheProductionBundleIdentifierEnablesTheUpdater() {
        for identifier in [nil, "com.sudohg.askkey.app.dev", "com.sudohg.askkey.app.e2e", "com.example.askkey"] as [String?] {
            var info = releaseInfo
            info["CFBundleIdentifier"] = identifier
            XCTAssertFalse(
                SoftwareUpdateAvailability.isEnabled(infoDictionary: info, topology: .accepted(helperURL: officialHelper)),
                "bundle \(identifier ?? "nil")"
            )
        }
    }

    func testOnlyTheAcceptedOfficialTopologyEnablesTheUpdater() {
        let rejected: [OfficialInstallDecision] = [
            .developmentAccepted(helperURL: officialHelper),
            .relocatedOrRenamed,
            .helperMismatch,
        ]
        for topology in rejected {
            XCTAssertFalse(
                SoftwareUpdateAvailability.isEnabled(infoDictionary: releaseInfo, topology: topology),
                "\(topology)"
            )
        }
    }

    func testTopologyDecisionForInstalledAndRelocatedCopies() {
        let official = OfficialInstallTopology.decide(
            bundleURL: URL(fileURLWithPath: OfficialInstallTopology.canonicalAppPath, isDirectory: true),
            isDevelopmentBuild: false,
            resolvedURL: { $0 }
        )
        XCTAssertTrue(SoftwareUpdateAvailability.isEnabled(infoDictionary: releaseInfo, topology: official))

        let relocated = OfficialInstallTopology.decide(
            bundleURL: FileManager.default.temporaryDirectory.appendingPathComponent("Ask Key.app", isDirectory: true),
            isDevelopmentBuild: false,
            resolvedURL: { $0 }
        )
        XCTAssertFalse(SoftwareUpdateAvailability.isEnabled(infoDictionary: releaseInfo, topology: relocated))

        let development = OfficialInstallTopology.decide(
            bundleURL: URL(fileURLWithPath: OfficialInstallTopology.canonicalAppPath, isDirectory: true),
            isDevelopmentBuild: true,
            resolvedURL: { $0 }
        )
        XCTAssertFalse(SoftwareUpdateAvailability.isEnabled(infoDictionary: releaseInfo, topology: development))
    }

    func testOnlyTheProductionExecutableImportsSparkle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var importers: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.range(of: #"(?m)^\s*import\s+Sparkle\b"#, options: .regularExpression) != nil {
                importers.append(String(file.path.dropFirst(root.path.count + 1)))
            }
        }
        XCTAssertEqual(importers, ["Sources/AskKeyApp/SparkleSoftwareUpdater.swift"])
    }
}
