import AppKit
import Darwin
import LocalAuthentication
import AskKeyVault

enum ManagementAuthenticationAction: CaseIterable {
    case manage, reveal, pause, resume
    case clearAccessRecords, eraseLibrary, revealFrozenFile
    case approveRead, approveWrite, permanentlyDelete, replaceImportedCredential
    case disableReadAuthentication, legacyRelease, legacyUnlock

    var reasonKey: String {
        switch self {
        case .manage: CredentialManagementCopy.manageReason
        case .reveal: CredentialManagementCopy.revealReason
        case .pause: CredentialManagementCopy.pauseReason
        case .resume: CredentialManagementCopy.resumeReason
        case .clearAccessRecords: "Clear Ask Key access records"
        case .eraseLibrary: "Erase the local Ask Key vault"
        case .revealFrozenFile: "View the frozen file submitted for approval"
        case .approveRead: "Approve this Agent credential request"
        case .approveWrite: "Approve this Agent credential change"
        case .permanentlyDelete: "Permanently delete recycled credential"
        case .replaceImportedCredential: "Replace credential with imported values"
        case .disableReadAuthentication: "Disable system authentication for read approvals"
        case .legacyRelease: "Release %@ (%@) in project %@ to %@"
        case .legacyUnlock: "Unlock the AskKey vault for %@"
        }
    }

    var argumentCount: Int {
        switch self {
        case .legacyRelease: 4
        case .legacyUnlock: 1
        default: 0
        }
    }
}

package struct ManagementAuthenticationPresentation: Equatable, Sendable {
    let title: String
    let reason: String
    let language: String
    let reasonKey: String
    let reasonArguments: [String]

    init(reasonKey: String, reasonArguments: [String] = [], language: String) {
        self.title = AppLanguage.brandName(language: language)
        let format = AppLanguage.localized(reasonKey, language: language)
        self.reason = String(
            format: format,
            locale: Locale(identifier: language),
            arguments: reasonArguments.map { $0 as CVarArg }
        )
        self.language = language
        self.reasonKey = reasonKey
        self.reasonArguments = reasonArguments
    }

    static func current(reason: String, arguments: [String] = []) -> Self {
        let language = AppLanguage.current
        return Self(
            reasonKey: reason,
            reasonArguments: arguments,
            language: language
        )
    }

    static func current(
        reason: String,
        arguments: (String) -> [String]
    ) -> Self {
        let language = AppLanguage.current
        return Self(
            reasonKey: reason,
            reasonArguments: arguments(language),
            language: language
        )
    }
}

package enum ManagementAuthenticationOutcome: String, Codable, Equatable, Sendable {
    case authenticated
    case cancelled
    case failed

    static func classify(_ error: Error) -> Self {
        let value = error as NSError
        guard value.domain == LAError.errorDomain else { return .failed }
        let cancellationCodes = [
            LAError.userCancel.rawValue,
            LAError.systemCancel.rawValue,
            LAError.appCancel.rawValue,
        ]
        return cancellationCodes.contains(value.code) ? .cancelled : .failed
    }
}

struct ManagementAuthenticationDescription: Codable, Equatable, Sendable {
    let title: String
    let reason: String
    let normalRuntimeInitialized: Bool
}

struct ManagementAuthenticationResponse: Codable {
    let outcome: ManagementAuthenticationOutcome
}

private struct ManagementAuthenticationPayload: Codable {
    let reasonKey: String
    let reasonArguments: [String]
}

enum ManagementAuthenticationSubprocess {
    static let policy = LAPolicy.deviceOwnerAuthentication
    @MainActor private static var finished = false

    private static let authenticateFlag = "--askkey-authenticate"
    private static let describeFlag = "--askkey-authenticate-describe"
    private static let maximumPayloadBytes = 16 * 1024
    // A single action catalog owns the wire reason and argument count. Call sites
    // use these actions; localization is presentation, never an extra allow-list.
    private static let allowedReasonArgumentCounts = Dictionary(
        uniqueKeysWithValues: ManagementAuthenticationAction.allCases.map {
            ($0.reasonKey, $0.argumentCount)
        }
    )

    struct Request {
        let language: String
        let describeOnly: Bool
    }

    static var request: Request? {
        parse(arguments: CommandLine.arguments)
    }

    static var isActive: Bool { request != nil }

    static func arguments(
        language: String,
        describeOnly: Bool
    ) -> [String] {
        [
            "-AppleLanguages", "(\(language))",
            describeOnly ? describeFlag : authenticateFlag,
        ]
    }

    static func payloadData(
        presentation: ManagementAuthenticationPresentation
    ) -> Data {
        (try? JSONEncoder().encode(ManagementAuthenticationPayload(
            reasonKey: presentation.reasonKey,
            reasonArguments: presentation.reasonArguments
        ))) ?? Data()
    }

    static func payloadIsWithinLimit(
        presentation: ManagementAuthenticationPresentation
    ) -> Bool {
        var data = payloadData(presentation: presentation)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        return !data.isEmpty && data.count <= maximumPayloadBytes
    }

    @MainActor
    static func startIfRequested() -> Bool {
        guard let request else { return false }
        NSApp.setActivationPolicy(.accessory)
        guard let presentation = readPresentation(language: request.language) else {
            writeAndTerminate(ManagementAuthenticationResponse(outcome: .failed))
            return true
        }
        let runtimeTitle = Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.localizedInfoDictionary?["CFBundleName"] as? String
            ?? ""
        if request.describeOnly {
            writeAndTerminate(ManagementAuthenticationDescription(
                title: runtimeTitle,
                reason: presentation.reason,
                normalRuntimeInitialized: AppRuntimeState.normalRuntimeInitialized
            ))
            return true
        }
        guard parentExecutableMatches(),
              runtimeTitle == presentation.title else {
            writeAndTerminate(ManagementAuthenticationResponse(outcome: .failed))
            return true
        }
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(policy, error: &policyError) else {
            writeAndTerminate(ManagementAuthenticationResponse(outcome: .failed))
            return true
        }
        // The Touch ID prompt belongs to this process. Bring it forward so the
        // prompt has focus and the sensor is ready without an extra click; the
        // parent also yields activation to this process when it is active.
        NSApp.activate(ignoringOtherApps: true)
        let completion = ManagementAuthenticationChildCompletion(invalidate: { context.invalidate() }) { outcome in
            writeAndTerminate(ManagementAuthenticationResponse(outcome: outcome))
        }
        // The payload ends with a newline; stdin then becomes a cancellation
        // channel. EOF also cancels if the parent exits unexpectedly.
        FileHandle.standardInput.readabilityHandler = { input in
            _ = input.availableData
            input.readabilityHandler = nil
            DispatchQueue.main.async {
                completion.finish(.cancelled)
            }
        }
        context.evaluatePolicy(
            policy,
            localizedReason: presentation.reason
        ) { success, error in
            let outcome: ManagementAuthenticationOutcome
            if success {
                outcome = .authenticated
            } else if let error {
                outcome = ManagementAuthenticationOutcome.classify(error)
            } else {
                outcome = .failed
            }
            DispatchQueue.main.async {
                completion.finish(outcome)
            }
        }
        return true
    }

    static func parse(arguments: [String]) -> Request? {
        guard arguments.count == 4,
              arguments[1] == "-AppleLanguages" else { return nil }
        let language = arguments[2]
            .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        guard language == "en" || language == "zh-Hans" else { return nil }
        let describeOnly: Bool
        switch arguments[3] {
        case describeFlag: describeOnly = true
        case authenticateFlag: describeOnly = false
        default: return nil
        }
        return Request(
            language: language,
            describeOnly: describeOnly
        )
    }

    static func readPresentation(
        language: String,
        readChunk: () throws -> Data? = {
            try FileHandle.standardInput.read(upToCount: 1)
        }
    ) -> ManagementAuthenticationPresentation? {
        var data = Data()
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        do {
            while var chunk = try readChunk() {
                if chunk.isEmpty { break }
                data.append(chunk)
                chunk.resetBytes(in: chunk.startIndex..<chunk.endIndex)
                let framed = data.last == 0x0a
                if framed { data.removeLast() }
                guard data.count <= maximumPayloadBytes else { return nil }
                if framed { break }
            }
        } catch {
            return nil
        }
        guard !data.isEmpty else { return nil }
        guard let payload = try? JSONDecoder().decode(
            ManagementAuthenticationPayload.self,
            from: data
        ), accepts(
            reasonKey: payload.reasonKey,
            argumentCount: payload.reasonArguments.count
        ) else { return nil }
        return ManagementAuthenticationPresentation(
            reasonKey: payload.reasonKey,
            reasonArguments: payload.reasonArguments,
            language: language
        )
    }

    static func accepts(reasonKey: String, argumentCount: Int) -> Bool {
        allowedReasonArgumentCounts[reasonKey] == argumentCount
    }

    static func parentExecutableMatches(
        parentPID: pid_t = getppid(),
        executableURL: URL? = Bundle.main.executableURL
    ) -> Bool {
        guard let executableURL else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = proc_pidpath(parentPID, &buffer, UInt32(buffer.count))
        guard count > 0 else { return false }
        let parentURL = URL(fileURLWithPath: String(cString: buffer))
            .resolvingSymlinksInPath().standardizedFileURL
        return parentURL == executableURL.resolvingSymlinksInPath().standardizedFileURL
    }

    @MainActor
    private static func writeAndTerminate<T: Encodable>(_ value: T) {
        guard !finished else { return }
        finished = true
        FileHandle.standardInput.readabilityHandler = nil
        if let data = try? JSONEncoder().encode(value) {
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
        // Let the app take focus back if it was in front before the prompt.
        if let parent = NSRunningApplication(processIdentifier: getppid()) {
            NSApp.yieldActivation(to: parent)
        }
        NSApp.terminate(nil)
    }
}
