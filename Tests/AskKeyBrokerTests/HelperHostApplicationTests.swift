import XCTest
@testable import AskKeyBroker

final class HelperHostApplicationTests: XCTestCase {
    func testOpenableBundleURLRejectsUnsignedNoncanonicalInvalidPlist() throws {
        let fixture = try makeHostFixture(
            appName: "Unrelated.app",
            infoPlist: Data("not even a plist".utf8),
            helperContents: Data("plain text helper\n".utf8)
        )
        XCTAssertNil(HelperHostApplication.openableBundleURL(fromHelperExecutable: fixture.helper))
    }

    func testReleaseOpenDoesNotOpenUnsignedNoncanonicalInvalidPlist() throws {
        let fixture = try makeHostFixture(
            appName: "Unrelated.app",
            infoPlist: Data("not even a plist".utf8),
            helperContents: Data("plain text helper\n".utf8)
        )
        let opened = OpenRecorder()
        XCTAssertThrowsError(
            try HelperHostApplication.openHost(
                helperURL: fixture.helper,
                isDevelopmentBuild: false,
                opener: opened.record
            )
        ) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(
                text.contains("/Applications/Ask Key.app"),
                "Release rejection must name the official path, got \(text)"
            )
            XCTAssertTrue(
                text.localizedCaseInsensitiveContains("reinstall"),
                "Release rejection must tell the user to reinstall, got \(text)"
            )
        }
        XCTAssertTrue(opened.urls.isEmpty)
        XCTAssertFalse(fixture.app.path.hasPrefix("/Applications"))
    }

    func testReleaseOpenDoesNotOpenMovedHost() throws {
        let fixture = try makeHostFixture(
            appName: "Ask Key.app",
            bundleIdentifier: "com.sudohg.askkey.app"
        )
        let opened = OpenRecorder()
        XCTAssertThrowsError(
            try HelperHostApplication.openHost(
                helperURL: fixture.helper,
                isDevelopmentBuild: false,
                opener: opened.record
            )
        )
        XCTAssertTrue(opened.urls.isEmpty)
        XCTAssertNotEqual(fixture.app.path, "/Applications/Ask Key.app")
    }

    func testReleaseOpenDoesNotOpenRenamedHost() throws {
        let opened = OpenRecorder()
        XCTAssertThrowsError(
            try HelperHostApplication.openHost(
                helperURL: URL(fileURLWithPath: "/Applications/AskKey.app/Contents/Helpers/askkey"),
                isDevelopmentBuild: false,
                opener: opened.record,
                bundleIdentifier: { _ in "com.sudohg.askkey.app" },
                resolvedURL: { $0 }
            )
        )
        XCTAssertTrue(opened.urls.isEmpty)
    }

    func testReleaseOpenDoesNotOpenWrongBundleIdentifier() throws {
        let opened = OpenRecorder()
        XCTAssertThrowsError(
            try HelperHostApplication.openHost(
                helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
                isDevelopmentBuild: false,
                opener: opened.record,
                bundleIdentifier: { _ in "com.example.unrelated" },
                resolvedURL: { $0 }
            )
        ) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(text.localizedCaseInsensitiveContains("reinstall"), text)
        }
        XCTAssertTrue(opened.urls.isEmpty)
    }

    func testReleaseOpenDoesNotOpenMismatchedSignature() throws {
        let opened = OpenRecorder()
        XCTAssertThrowsError(
            try HelperHostApplication.openHost(
                helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
                isDevelopmentBuild: false,
                opener: opened.record,
                signingFacts: { url in
                    if url.lastPathComponent == "askkey" {
                        return HelperHostSigningFacts(
                            teamIdentifier: "TEAMIDAAAA",
                            certificateSummaries: ["Developer ID Application: Helper (TEAMIDAAAA)"],
                            flags: 0,
                            isValid: true,
                            meetsAppleDeveloperIDRequirement: true
                        )
                    }
                    return HelperHostSigningFacts(
                        teamIdentifier: "TEAMIDBBBB",
                        certificateSummaries: ["Developer ID Application: Host (TEAMIDBBBB)"],
                        flags: 0,
                        isValid: true,
                        meetsAppleDeveloperIDRequirement: true
                    )
                },
                bundleIdentifier: { _ in "com.sudohg.askkey.app" },
                resolvedURL: { $0 }
            )
        ) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(text.localizedCaseInsensitiveContains("reinstall"), text)
        }
        XCTAssertTrue(opened.urls.isEmpty)
    }

    func testReleaseOpenDoesNotOpenExternalHelper() throws {
        let loose = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-external-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: loose)
        addTeardownBlock { try? FileManager.default.removeItem(at: loose) }
        let opened = OpenRecorder()
        XCTAssertThrowsError(
            try HelperHostApplication.openHost(
                helperURL: loose,
                isDevelopmentBuild: false,
                opener: opened.record
            )
        )
        XCTAssertTrue(opened.urls.isEmpty)
        XCTAssertFalse(loose.path.hasPrefix("/Applications"))
    }

    func testReleaseOpenAllowsOfficialPathOnlyAsARuleWithInjectedSignature() throws {
        // Rule-only fixture through the same allows() path. Real Developer ID
        // signing remains pending_human and this test does not read /Applications.
        let opened = OpenRecorder()
        try HelperHostApplication.openHost(
            helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
            isDevelopmentBuild: false,
            opener: opened.record,
            signingFacts: { _ in Self.matchingDeveloperIDFacts },
            bundleIdentifier: { _ in "com.sudohg.askkey.app" },
            resolvedURL: { $0 }
        )
        XCTAssertEqual(opened.urls.map(\.path), ["/Applications/Ask Key.app"])
    }

    func testReleaseOpenIgnoresDebugEnvironmentAndStillRejectsMovedHost() throws {
        let fixture = try makeHostFixture(
            appName: "Ask Key.app",
            bundleIdentifier: "com.sudohg.askkey.app"
        )
        let previous = getenv("ASKKEY_DEBUG_RUN_DIRECTORY").map { String(cString: $0) }
        setenv("ASKKEY_DEBUG_RUN_DIRECTORY", fixture.root.path, 1)
        addTeardownBlock {
            if let previous {
                setenv("ASKKEY_DEBUG_RUN_DIRECTORY", previous, 1)
            } else {
                unsetenv("ASKKEY_DEBUG_RUN_DIRECTORY")
            }
        }
        let opened = OpenRecorder()
        XCTAssertThrowsError(
            try HelperHostApplication.openHost(
                helperURL: fixture.helper,
                isDevelopmentBuild: false,
                opener: opened.record
            )
        )
        XCTAssertTrue(opened.urls.isEmpty)
    }

    func testDebugOpenAllowsIsolatedHostWithoutTouchingApplications() throws {
        let fixture = try makeHostFixture(
            appName: "AskKeyApp.app",
            bundleIdentifier: "com.sudohg.askkey.app.dev"
        )
        XCTAssertFalse(fixture.app.path.hasPrefix("/Applications"))
        let opened = OpenRecorder()
        try HelperHostApplication.openHost(
            helperURL: fixture.helper,
            isDevelopmentBuild: true,
            opener: opened.record,
            signingFacts: { _ in Self.matchingAdhocFacts }
        )
        XCTAssertEqual(opened.urls, [fixture.app.standardizedFileURL.resolvingSymlinksInPath()])
        XCTAssertNotEqual(fixture.helper.path, "/Applications/Ask Key.app/Contents/Helpers/askkey")
    }

    func testDebugOpenDoesNotOpenInvalidPlistOnIsolatedHost() throws {
        let fixture = try makeHostFixture(
            appName: "Unrelated.app",
            infoPlist: Data("not even a plist".utf8)
        )
        let opened = OpenRecorder()
        XCTAssertThrowsError(
            try HelperHostApplication.openHost(
                helperURL: fixture.helper,
                isDevelopmentBuild: true,
                opener: opened.record
            )
        )
        XCTAssertTrue(opened.urls.isEmpty)
    }

    func testDebugOpenDoesNotOpenUnsignedIsolatedHostWithDefaultSignatureCheck() throws {
        let fixture = try makeHostFixture(
            appName: "AskKeyApp.app",
            bundleIdentifier: "com.sudohg.askkey.app.dev"
        )
        let opened = OpenRecorder()
        XCTAssertThrowsError(
            try HelperHostApplication.openHost(
                helperURL: fixture.helper,
                isDevelopmentBuild: true,
                opener: opened.record
            )
        )
        XCTAssertTrue(opened.urls.isEmpty)
    }

    func testReleaseOpenRejectsMatchingAdhocFactsAndDoesNotOpen() throws {
        let opened = OpenRecorder()
        XCTAssertThrowsError(
            try HelperHostApplication.openHost(
                helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
                isDevelopmentBuild: false,
                opener: opened.record,
                signingFacts: { _ in Self.matchingAdhocFacts },
                bundleIdentifier: { _ in "com.sudohg.askkey.app" },
                resolvedURL: { $0 }
            )
        ) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(text.localizedCaseInsensitiveContains("reinstall"), text)
        }
        XCTAssertTrue(opened.urls.isEmpty)
    }

    func testDebugOpenAllowsMatchingAdhocFactsOnIsolatedHost() throws {
        let fixture = try makeHostFixture(
            appName: "AskKeyApp.app",
            bundleIdentifier: "com.sudohg.askkey.app.dev"
        )
        let opened = OpenRecorder()
        try HelperHostApplication.openHost(
            helperURL: fixture.helper,
            isDevelopmentBuild: true,
            opener: opened.record,
            signingFacts: { _ in Self.matchingAdhocFacts }
        )
        XCTAssertEqual(opened.urls, [fixture.app.standardizedFileURL.resolvingSymlinksInPath()])
        XCTAssertFalse(fixture.app.path.hasPrefix("/Applications"))
    }

    func testReleaseOpenRejectsIncompleteDeveloperIDMaterials() throws {
        let opened = OpenRecorder()
        XCTAssertThrowsError(
            try HelperHostApplication.openHost(
                helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
                isDevelopmentBuild: false,
                opener: opened.record,
                signingFacts: { _ in
                    HelperHostSigningFacts(
                        teamIdentifier: "TEAMID1234",
                        certificateSummaries: [],
                        flags: 0,
                        isValid: true
                    )
                },
                bundleIdentifier: { _ in "com.sudohg.askkey.app" },
                resolvedURL: { $0 }
            )
        )
        XCTAssertTrue(opened.urls.isEmpty)
    }

    func testReleaseOpenRejectsMismatchedDeveloperIDTeams() throws {
        let opened = OpenRecorder()
        XCTAssertThrowsError(
            try HelperHostApplication.openHost(
                helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
                isDevelopmentBuild: false,
                opener: opened.record,
                signingFacts: { url in
                    if url.lastPathComponent == "askkey" {
                        return HelperHostSigningFacts(
                            teamIdentifier: "TEAMIDAAAA",
                            certificateSummaries: ["Developer ID Application: Helper (TEAMIDAAAA)"],
                            flags: 0,
                            isValid: true,
                            meetsAppleDeveloperIDRequirement: true
                        )
                    }
                    return HelperHostSigningFacts(
                        teamIdentifier: "TEAMIDBBBB",
                        certificateSummaries: ["Developer ID Application: Host (TEAMIDBBBB)"],
                        flags: 0,
                        isValid: true,
                        meetsAppleDeveloperIDRequirement: true
                    )
                },
                bundleIdentifier: { _ in "com.sudohg.askkey.app" },
                resolvedURL: { $0 }
            )
        )
        XCTAssertTrue(opened.urls.isEmpty)
    }

    func testReleaseOpenRejectsSpoofedDeveloperIDNameWithoutAppleRequirement() throws {
        let opened = OpenRecorder()
        XCTAssertThrowsError(
            try HelperHostApplication.openHost(
                helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
                isDevelopmentBuild: false,
                opener: opened.record,
                signingFacts: { _ in
                    HelperHostSigningFacts(
                        teamIdentifier: "TEAMID1234",
                        certificateSummaries: ["Developer ID Application: Ask Key (TEAMID1234)"],
                        flags: 0,
                        isValid: true,
                        meetsAppleDeveloperIDRequirement: false
                    )
                },
                bundleIdentifier: { _ in "com.sudohg.askkey.app" },
                resolvedURL: { $0 }
            )
        ) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(text.localizedCaseInsensitiveContains("reinstall"), text)
        }
        XCTAssertTrue(opened.urls.isEmpty)
    }

    func testAppleDeveloperIDRequirementUsesAppleAnchorAndCertificateOIDs() {
        let text = HelperHostSignatureTrust.appleDeveloperIDRequirementText
        XCTAssertTrue(text.contains("anchor apple generic"), text)
        XCTAssertTrue(text.contains("1.2.840.113635.100.6.2.6"), text)
        XCTAssertTrue(text.contains("1.2.840.113635.100.6.1.13"), text)
        XCTAssertTrue(HelperHostSignatureTrust.appleDeveloperIDRequirementIsAvailable)
    }

    func testSystemSigningFactsExecuteAppleDeveloperIDRequirement() throws {
        let unsigned = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-unsigned-\(UUID().uuidString)")
        try Data("plain text helper\n".utf8).write(to: unsigned)
        addTeardownBlock { try? FileManager.default.removeItem(at: unsigned) }
        let unsignedFacts = HelperHostApplication.signingFacts(at: unsigned)
        XCTAssertFalse(unsignedFacts.isValid)
        XCTAssertFalse(unsignedFacts.meetsAppleDeveloperIDRequirement)

        let adhoc = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-adhoc-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: adhoc)
        addTeardownBlock { try? FileManager.default.removeItem(at: adhoc) }
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", adhoc.path]
        try codesign.run()
        codesign.waitUntilExit()
        XCTAssertEqual(codesign.terminationStatus, 0)
        let adhocFacts = HelperHostApplication.signingFacts(at: adhoc)
        XCTAssertTrue(adhocFacts.isValid)
        XCTAssertFalse(adhocFacts.meetsAppleDeveloperIDRequirement)

        let platform = HelperHostApplication.signingFacts(at: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertTrue(platform.isValid)
        XCTAssertFalse(platform.meetsAppleDeveloperIDRequirement)
    }

    func testReleaseOpenRejectsInvalidSignatureFacts() throws {
        let opened = OpenRecorder()
        XCTAssertThrowsError(
            try HelperHostApplication.openHost(
                helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
                isDevelopmentBuild: false,
                opener: opened.record,
                signingFacts: { _ in
                    HelperHostSigningFacts(
                        teamIdentifier: "TEAMID1234",
                        certificateSummaries: ["Developer ID Application: Ask Key (TEAMID1234)"],
                        flags: 0,
                        isValid: false
                    )
                },
                bundleIdentifier: { _ in "com.sudohg.askkey.app" },
                resolvedURL: { $0 }
            )
        )
        XCTAssertTrue(opened.urls.isEmpty)
    }

    func testResolvesHostAppFromHelpersLayoutWithoutHardcodingApplications() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyOpen-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Ask Key Dev.app", isDirectory: true)
        let helper = app.appendingPathComponent("Contents/Helpers/askkey")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.sudohg.askkey.app.dev",
                "CFBundleName": "Ask Key Dev",
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Contents/Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            HelperHostApplication.bundleURL(fromHelperExecutable: helper),
            app.standardizedFileURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(
            HelperHostApplication.openableBundleURL(fromHelperExecutable: helper),
            app.standardizedFileURL.resolvingSymlinksInPath()
        )
        XCTAssertFalse(app.path.hasPrefix("/Applications"))
    }

    func testRejectsHelpersThatAreNotInsideAnAppBundle() throws {
        let loose = FileManager.default.temporaryDirectory.appendingPathComponent("askkey-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: loose)
        addTeardownBlock { try? FileManager.default.removeItem(at: loose) }
        XCTAssertNil(HelperHostApplication.bundleURL(fromHelperExecutable: loose))
        XCTAssertNil(HelperHostApplication.openableBundleURL(fromHelperExecutable: loose))
        let opened = OpenRecorder()
        XCTAssertThrowsError(
            try HelperHostApplication.openHost(
                helperURL: loose,
                isDevelopmentBuild: true,
                opener: opened.record
            )
        )
        XCTAssertTrue(opened.urls.isEmpty)
    }

    private static let matchingAdhocFacts = HelperHostSigningFacts(
        teamIdentifier: nil,
        certificateSummaries: [],
        flags: HelperHostSignatureTrust.adHocFlag,
        isValid: true
    )

    private static let matchingDeveloperIDFacts = HelperHostSigningFacts(
        teamIdentifier: "TEAMID1234",
        certificateSummaries: ["Developer ID Application: Ask Key (TEAMID1234)"],
        flags: 0,
        isValid: true,
        meetsAppleDeveloperIDRequirement: true
    )

    private struct HostFixture {
        let root: URL
        let app: URL
        let helper: URL
    }

    private final class OpenRecorder: @unchecked Sendable {
        private(set) var urls: [URL] = []
        func record(_ url: URL) {
            urls.append(url)
        }
    }

    private func makeHostFixture(
        appName: String,
        bundleIdentifier: String? = nil,
        infoPlist: Data? = nil,
        helperContents: Data = Data("#!/bin/sh\n".utf8)
    ) throws -> HostFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyOpenGate-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent(appName, isDirectory: true)
        let helper = app.appendingPathComponent("Contents/Helpers/askkey")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try helperContents.write(to: helper)
        let plist: Data
        if let infoPlist {
            plist = infoPlist
        } else if let bundleIdentifier {
            plist = try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleIdentifier": bundleIdentifier,
                    "CFBundleName": "Ask Key",
                    "CFBundlePackageType": "APPL",
                ],
                format: .xml,
                options: 0
            )
        } else {
            plist = Data("<?xml version=\"1.0\"?><plist><dict></dict></plist>".utf8)
        }
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return HostFixture(root: root, app: app, helper: helper)
    }
}
