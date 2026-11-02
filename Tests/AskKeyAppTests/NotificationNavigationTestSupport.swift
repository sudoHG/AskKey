import Foundation
import AskKeyBroker
import AskKeyVault
@testable import AskKeyAppKit

@MainActor
final class ApprovalPromptRecorder {
    var count = 0
    var receivedOnlyUntargetedPrompts = true

    func observe() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .presentNextAgentApproval, object: nil, queue: .main
        ) { [self] note in
            MainActor.assumeIsolated {
                count += 1
                receivedOnlyUntargetedPrompts = receivedOnlyUntargetedPrompts && note.object == nil
            }
        }
    }
}

@MainActor
final class NotificationNavigationFixture {
    var credentials: [ManagedTextCredential]
    var recycled: [ManagedTextCredential] = []
    var loads = 0
    var authentications = 0
    var failLoading = false
    var authenticationResult: ManagementAuthenticationResult = .authenticated(.allow)
    let defaults: UserDefaults
    private let policy = AgentAccessPolicyTestState()

    lazy var vault = VaultViewModel(
        runtimeFileCleanupFailures: { false }, accessRecords: .empty,
        unlockVault: {}, beginManagementSession: { _ in },
        authenticateDeviceOwner: { [unowned self] _ in
            authentications += 1
            return authenticationResult
        },
        preferences: AppPreferences(defaults: defaults),
        loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
        agentAccessPolicyOperations: policy.operations,
        credentialMutations: CredentialWorkspaceMutations.readOnly { [unowned self] in
            loads += 1
            if failLoading { throw CocoaError(.fileReadCorruptFile) }
            return (credentials, recycled, ["SYNTHETIC target group"], false)
        }.counting { [unowned self] in credentials.count }
    )

    init(id: String, defaults: UserDefaults) {
        self.defaults = defaults
        credentials = [.init(
            id: id, name: "SYNTHETIC notification target", value: nil,
            usageInstructions: "SYNTHETIC", privateNotes: nil,
            groupName: "SYNTHETIC target group", environmentVariable: nil,
            permission: .ask, expiresAt: nil, payloadKind: .bundle,
            originalFilename: nil, byteSize: nil, contentDigest: nil,
            fileBytes: nil, components: [.init(name: "SYNTHETIC_FIELD", value: nil)]
        )]
    }
}
