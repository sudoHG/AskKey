import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeySystem

final class FakeCodexCLI: @unchecked Sendable {
    enum Kind {
        case missing
        case supported(String, rewriteWithoutComments: Bool)
        case unknown(String?)
    }

    private let kind: Kind
    private let helperURL: URL
    private let configURL: URL
    private(set) var addCalled = false

    init(kind: Kind, helperURL: URL, configURL: URL) {
        self.kind = kind
        self.helperURL = helperURL
        self.configURL = configURL
    }

    var command: CodexMCPCommand {
        CodexMCPCommand(
            status: { [kind] in
                switch kind {
                case .missing: return .missing
                case .supported(let version, _): return .supported(version: version)
                case .unknown(let version): return .unknown(version: version)
                }
            },
            addAskKey: { [weak self] helper, config in
                guard let self else { return }
                self.addCalled = true
                guard case .supported(_, let rewrite) = self.kind, rewrite else { return }
                let body = """
                [mcp_servers.askkey]
                command = "\(helper.path)"
                args = ["mcp"]
                """
                try FileManager.default.createDirectory(
                    at: config.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(body.utf8).write(to: config)
            }
        )
    }
}
