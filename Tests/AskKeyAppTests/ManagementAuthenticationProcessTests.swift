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

    /// Pairing confirmation asks with its own reason (#288), which the
    /// authentication subprocess accepts and shows in either language.
    func testPackagedSubprocessAcceptsAndDescribesThePairingReason() throws {
        let action = ManagementAuthenticationAction.pairDevice
        XCTAssertEqual(action.reasonKey, "Pair a device with this Mac")
        XCTAssertNotEqual(action.reasonKey, CredentialManagementCopy.manageReason)
        XCTAssertTrue(ManagementAuthenticationSubprocess.accepts(reasonKey: action.reasonKey, argumentCount: 0))
        XCTAssertFalse(ManagementAuthenticationSubprocess.accepts(reasonKey: action.reasonKey, argumentCount: 1))
        let chinese = try describePackagedAuthentication(
            presentation: ManagementAuthenticationPresentation(reasonKey: action.reasonKey, language: "zh-Hans")
        )
        XCTAssertEqual(chinese.title, "请旨")
        XCTAssertEqual(chinese.reason, "确认将设备与这台 Mac 配对")
        let english = try describePackagedAuthentication(
            presentation: ManagementAuthenticationPresentation(reasonKey: action.reasonKey, language: "en")
        )
        XCTAssertEqual(english.reason, "Pair a device with this Mac")
    }

    /// Turning a paired iPhone's approval on asks with its own reason (#313).
    func testPackagedSubprocessAcceptsAndDescribesTheApproverReason() throws {
        let action = ManagementAuthenticationAction.approveDevice
        XCTAssertEqual(action.reasonKey, "Let a paired iPhone approve Agent requests")
        XCTAssertNotEqual(action.reasonKey, CredentialManagementCopy.manageReason)
        XCTAssertTrue(ManagementAuthenticationSubprocess.accepts(reasonKey: action.reasonKey, argumentCount: 0))
        let chinese = try describePackagedAuthentication(
            presentation: ManagementAuthenticationPresentation(reasonKey: action.reasonKey, language: "zh-Hans")
        )
        XCTAssertEqual(chinese.reason, "确认让已配对的 iPhone 审批 Agent 请求") // i18n-literal: Assert the Simplified Chinese catalog value.
        let english = try describePackagedAuthentication(
            presentation: ManagementAuthenticationPresentation(reasonKey: action.reasonKey, language: "en")
        )
        XCTAssertEqual(english.reason, "Let a paired iPhone approve Agent requests")
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

    func testPayloadReaderLeavesTheCancellationChannelOpenAfterNewline() {
        let expected = ManagementAuthenticationPresentation(
            reasonKey: CredentialManagementCopy.manageReason, language: "en"
        )
        var framed = ManagementAuthenticationSubprocess.payloadData(presentation: expected)
        framed.append(0x0a)
        var chunks = [framed, Data("cancel\n".utf8)]
        XCTAssertEqual(ManagementAuthenticationSubprocess.readPresentation(
            language: "en", readChunk: { chunks.removeFirst() }
        ), expected)
        XCTAssertEqual(chunks, [Data("cancel\n".utf8)])
    }

    func testNewlineFramingPreservesTheMaximumPayloadBoundary() {
        let empty = ManagementAuthenticationPresentation(
            reasonKey: ManagementAuthenticationAction.legacyUnlock.reasonKey,
            reasonArguments: [""], language: "en"
        )
        let overhead = ManagementAuthenticationSubprocess.payloadData(presentation: empty).count
        for excess in [0, 1] {
            let expected = ManagementAuthenticationPresentation(
                reasonKey: empty.reasonKey,
                reasonArguments: [String(repeating: "x", count: 16 * 1024 - overhead + excess)], language: "en"
            )
            var framed = ManagementAuthenticationSubprocess.payloadData(presentation: expected)
            XCTAssertEqual(framed.count, 16 * 1024 + excess)
            framed.append(0x0a)
            let decoded = ManagementAuthenticationSubprocess.readPresentation(language: "en", readChunk: { framed })
            XCTAssertEqual(decoded, excess == 0 ? expected : nil)
        }
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
        try copyRuntimeDependencies(resources: resources, executableDirectory: executableDirectory)
        try copyInfoLocalization("en", to: resources)
        try copyInfoLocalization("zh-Hans", to: resources)
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleName</key><string>Ask Key</string>
          <key>CFBundleDisplayName</key><string>Ask Key</string>
          <key>LSHasLocalizedDisplayName</key><true/>
          <key>CFBundleDevelopmentRegion</key><string>en</string>
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

    private func copyRuntimeDependencies(resources: URL, executableDirectory: URL) throws {
        let products = try appExecutable().deletingLastPathComponent()
        let found = try BuildProductLocator.locateRuntimeDependencies(searchRoots: [products])
        if let resourceBundle = found {
            try FileManager.default.copyItem(
                at: resourceBundle,
                to: resources.appendingPathComponent("AskKey_AskKeyAppKit.bundle")
            )
        }
        // AskKeyApp loads Sparkle through @rpath; @loader_path is the rpath that
        // still resolves once the executable leaves the build products directory.
        let sparkle = try XCTUnwrap(
            try BuildProductLocator.locateSparkleFramework(searchRoots: [products]),
            "AskKeyApp links Sparkle.framework, which the build products must contain"
        )
        try FileManager.default.copyItem(
            at: sparkle,
            to: executableDirectory.appendingPathComponent("Sparkle.framework")
        )
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
        locate("AskKey_AskKeyAppKit.bundle", searchRoots: searchRoots)
    }

    static func locateSparkleFramework(
        searchRoots: [URL]
    ) throws -> URL? {
        locate("Sparkle.framework", searchRoots: searchRoots)
    }

    /// The first item with this name: directly in a root, then anywhere below it.
    private static func locate(_ name: String, searchRoots: [URL]) -> URL? {
        for root in searchRoots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let direct = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for case let url as URL in enumerator where url.lastPathComponent == name {
                return url
            }
        }
        return nil
    }
}
