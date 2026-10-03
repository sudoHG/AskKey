import Foundation
import Darwin
import LocalAuthentication
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class ManagementAuthenticationProcessTests: AskKeyAppTestCase {
    func testPackagedSubprocessUsesManualLanguageAndDevicePasswordPolicy() throws {
        XCTAssertEqual(
            ManagementAuthenticationSubprocess.policy,
            .deviceOwnerAuthentication
        )

        let chinese = try describePackagedAuthentication(
            presentation: ManagementAuthenticationPresentation(
                reasonKey: CredentialManagementCopy.manageReason,
                language: "zh-Hans"
            )
        )
        XCTAssertEqual(chinese.title, "请旨")
        XCTAssertEqual(chinese.reason, "请确认以管理凭证")
        XCTAssertFalse(chinese.normalRuntimeInitialized)

        let english = try describePackagedAuthentication(
            presentation: ManagementAuthenticationPresentation(
                reasonKey: CredentialManagementCopy.manageReason,
                language: "en"
            )
        )
        XCTAssertEqual(english.title, "Ask Key")
        XCTAssertEqual(english.reason, "Confirm credential management")
        XCTAssertFalse(english.normalRuntimeInitialized)
        XCTAssertFalse(ManagementAuthenticationSubprocess.parentExecutableMatches())
        XCTAssertTrue(ManagementAuthenticationSubprocess.parentExecutableMatches(
            parentPID: getpid(),
            executableURL: Bundle.main.executableURL
        ))
        XCTAssertTrue(ManagementAuthenticationSubprocess.accepts(
            reasonKey: CredentialManagementCopy.manageReason,
            argumentCount: 0
        ))
        XCTAssertFalse(ManagementAuthenticationSubprocess.accepts(
            reasonKey: "Show any attacker-controlled prompt",
            argumentCount: 0
        ))
    }

    func testPackagedApprovalDescribeUsesTheLocalizedReadAndWriteReasons() throws {
        let reasons: [(ManagementAuthenticationAction, String)] = [
            (
                .approveRead,
                "授权 AI 助手使用所选凭证"
            ),
            (
                .approveWrite,
                "授权 AI 助手修改所选凭证"
            ),
        ]

        for (action, chineseReason) in reasons {
            XCTAssertTrue(
                ManagementAuthenticationSubprocess.accepts(
                    reasonKey: action.reasonKey,
                    argumentCount: action.argumentCount
                )
            )
            let chinese = try describePackagedAuthentication(
                presentation: ManagementAuthenticationPresentation(
                    reasonKey: action.reasonKey,
                    language: "zh-Hans"
                )
            )
            XCTAssertEqual(chinese.reason, chineseReason)

            let english = try describePackagedAuthentication(
                presentation: ManagementAuthenticationPresentation(
                    reasonKey: action.reasonKey,
                    language: "en"
                )
            )
            XCTAssertEqual(english.reason, action.reasonKey)
        }
    }

    func testAuthenticationArgumentsRejectUnknownDuplicateAndMixedModes() {
        let presentation = ManagementAuthenticationPresentation(
            reasonKey: CredentialManagementCopy.manageReason,
            language: "en"
        )
        let valid = ["AskKeyApp"] + ManagementAuthenticationSubprocess.arguments(
            language: presentation.language,
            describeOnly: false
        )
        XCTAssertEqual(valid, [
            "AskKeyApp", "-AppleLanguages", "(en)", "--askkey-authenticate",
        ])
        XCTAssertNotNil(ManagementAuthenticationSubprocess.parse(arguments: valid))
        XCTAssertNil(ManagementAuthenticationSubprocess.parse(
            arguments: valid + ["--unknown"]
        ))
        XCTAssertNil(ManagementAuthenticationSubprocess.parse(
            arguments: valid + ["--askkey-authenticate"]
        ))
        var mixed = valid
        mixed[3] = "--askkey-authenticate-describe"
        mixed.append("--askkey-authenticate")
        XCTAssertNil(ManagementAuthenticationSubprocess.parse(arguments: mixed))
        var unsupportedLanguage = valid
        unsupportedLanguage[2] = "(fr)"
        XCTAssertNil(ManagementAuthenticationSubprocess.parse(arguments: unsupportedLanguage))
    }

    func testRunnerTimesOutAndKillsAuthenticationSubprocess() async throws {
        let executable = try makeIgnoringTerminationExecutable()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = ManagementAuthenticationRunner(
            executableURL: executable,
            timeout: 0.1,
            terminationGrace: 0.05
        )
        let started = Date()

        let outcome = await runner.authenticate(presentation: .init(
            reasonKey: CredentialManagementCopy.manageReason,
            language: "en"
        ))

        XCTAssertEqual(outcome, .failed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testRunnerFailsClosedWhenChildClosesStdinImmediately() async {
        let runner = ManagementAuthenticationRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            timeout: 1,
            terminationGrace: 0.05
        )

        let outcome = await runner.authenticate(presentation: .init(
            reasonKey: CredentialManagementCopy.manageReason,
            language: "en"
        ))

        XCTAssertEqual(outcome, .failed)
    }

    func testPayloadReaderJoinsPartialPipeReadsUntilEOF() throws {
        let expected = ManagementAuthenticationPresentation(
            reasonKey: CredentialManagementCopy.manageReason,
            language: "en"
        )
        let payload = ManagementAuthenticationSubprocess.payloadData(
            presentation: expected
        )
        let midpoint = payload.index(payload.startIndex, offsetBy: payload.count / 2)
        var chunks = [Data(payload[..<midpoint]), Data(payload[midpoint...]), Data()]

        let decoded = ManagementAuthenticationSubprocess.readPresentation(
            language: "en",
            readChunk: { chunks.removeFirst() }
        )

        XCTAssertEqual(decoded, expected)
        XCTAssertTrue(chunks.isEmpty)
    }

    func testSuppressSIGPIPETurnsClosedPipeIntoEPIPE() {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[1]) }
        close(descriptors[0])
        XCTAssertTrue(ManagementAuthenticationRunner.suppressSIGPIPE(
            fileDescriptor: descriptors[1]
        ))
        XCTAssertEqual(fcntl(descriptors[1], F_GETNOSIGPIPE), 1)
        var byte: UInt8 = 1
        XCTAssertEqual(Darwin.write(descriptors[1], &byte, 1), -1)
        XCTAssertEqual(errno, EPIPE)
    }

    func testOversizedPayloadIsRejectedBeforeProcessLaunch() {
        let presentation = ManagementAuthenticationPresentation(
            reasonKey: "Unlock the AskKey vault for %@",
            reasonArguments: [String(repeating: "x", count: 20_000)],
            language: "en"
        )

        XCTAssertFalse(ManagementAuthenticationSubprocess.payloadIsWithinLimit(
            presentation: presentation
        ))
    }

    private func describePackagedAuthentication(
        presentation: ManagementAuthenticationPresentation
    ) throws -> ManagementAuthenticationDescription {
        let root = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("aka-runtime-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Ask Key.app", isDirectory: true)
        let executableDirectory = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let executable = executableDirectory.appendingPathComponent("AskKeyApp")
        try FileManager.default.copyItem(at: try appExecutable(), to: executable)
        try copyRuntimeDependencies(resources: resources)
        try copyInfoLocalization("en", to: resources)
        try copyInfoLocalization("zh-Hans", to: resources)
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleName</key><string>AskKey</string>
          <key>CFBundleDisplayName</key><string>AskKey</string>
          <key>CFBundleExecutable</key><string>AskKeyApp</string>
          <key>CFBundleIdentifier</key><string>com.sudohg.askkey.auth-test</string>
          <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """.utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))

        let process = Process()
        process.executableURL = executable
        process.arguments = ManagementAuthenticationSubprocess.arguments(
            language: presentation.language,
            describeOnly: true
        )
        process.environment = appTestEnvironment()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let payload = ManagementAuthenticationSubprocess.payloadData(
            presentation: presentation
        )
        let midpoint = payload.index(payload.startIndex, offsetBy: payload.count / 2)
        try input.fileHandleForWriting.write(contentsOf: payload[..<midpoint])
        Thread.sleep(forTimeInterval: 0.05)
        try input.fileHandleForWriting.write(contentsOf: payload[midpoint...])
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
        return try JSONDecoder().decode(
            ManagementAuthenticationDescription.self,
            from: output.fileHandleForReading.readDataToEndOfFile()
        )
    }

    private func copyInfoLocalization(_ language: String, to resources: URL) throws {
        let source = repoRoot()
            .appendingPathComponent("Sources/AskKeyAppKit/Resources")
            .appendingPathComponent("\(language).lproj/InfoPlist.strings")
        let destination = resources.appendingPathComponent("\(language).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source,
            to: destination.appendingPathComponent("InfoPlist.strings")
        )
    }

    private func makeIgnoringTerminationExecutable() throws -> URL {
        let directory = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("aka-stubborn-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("stubborn-auth")
        try Data("""
        #!/bin/sh
        trap '' TERM
        exec /bin/sleep 4
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path
        )
        return executable
    }

    private func appExecutable() throws -> URL {
        let candidate = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("AskKeyApp")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return candidate
    }

    func testRuntimeDependenciesAreFoundFromIsolatedBuildProducts() throws {
        let isolated = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyIsolatedProducts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: isolated) }
        let resources = isolated.appendingPathComponent("AskKey_AskKeyAppKit.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let found = try BuildProductLocator.locateRuntimeDependencies(searchRoots: [isolated])
        XCTAssertEqual(found?.path, resources.path)
    }

    func testRuntimeDependencySearchDoesNotRequireTheRepositoryBuildDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyLocator-\(UUID().uuidString)", isDirectory: true)
        let isolated = root.appendingPathComponent("scratch", isDirectory: true)
        let decoyBuild = root.appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("AskKey_AskKeyAppKit.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decoyBuild, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(
            try BuildProductLocator.locateRuntimeDependencies(searchRoots: [isolated])
        )
    }

    private func copyRuntimeDependencies(resources: URL) throws {
        let found = try BuildProductLocator.locateRuntimeDependencies(
            searchRoots: [try appExecutable().deletingLastPathComponent()]
        )
        if let resourceBundle = found {
            try FileManager.default.copyItem(
                at: resourceBundle,
                to: resources.appendingPathComponent("AskKey_AskKeyAppKit.bundle")
            )
        }
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

enum BuildProductLocator {
    static func locateRuntimeDependencies(
        searchRoots: [URL]
    ) throws -> URL? {
        var resourceBundle: URL?
        for root in searchRoots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let directResources = root.appendingPathComponent("AskKey_AskKeyAppKit.bundle")
            if resourceBundle == nil, FileManager.default.fileExists(atPath: directResources.path) {
                resourceBundle = directResources
            }
            if resourceBundle != nil { break }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for case let url as URL in enumerator {
                if resourceBundle == nil,
                   url.lastPathComponent == "AskKey_AskKeyAppKit.bundle" {
                    resourceBundle = url
                    enumerator.skipDescendants()
                }
                if resourceBundle != nil { break }
            }
            if resourceBundle != nil { break }
        }
        return resourceBundle
    }
}
