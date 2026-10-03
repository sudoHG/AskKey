# Architecture guide

AskKey keeps credential management and storage in a macOS application. Agents reach the application's local Broker through the `askkey` helper. The application decides permission, presents approval, and delivers approved values to a target process or a short-lived file. Public Broker responses do not return stored plaintext.

This guide describes the modules after Phase 6. The authorities for their boundaries are [Package.swift](../Package.swift) and [the module dependency checker](../scripts/check_module_deps.py). For client setup and validation, see [Client integrations](client-integrations.md) and [Testing](testing.md).

## Modules

| Target | Responsibility and entry points |
| --- | --- |
| `AskKeyBroker` | Versioned request and response types, bounded socket transport, approval state, file-write staging, and target execution. Start with [BrokerRequestHandler](../Sources/AskKeyBroker/BrokerRequestHandler.swift), [BrokerApprovalStateMachine](../Sources/AskKeyBroker/BrokerApprovalStateMachine.swift), [TextRuntime](../Sources/AskKeyBroker/TextRuntime.swift), and [RuntimeOperations](../Sources/AskKeyBroker/RuntimeOperations.swift). |
| `AskKeyBrokerC` | C boundary for descriptor passing and process-group execution, used by the Broker. |
| `AskKeyVault` | Credential operations, encrypted and authenticated records, GRDB/SQLite storage, App-owned keys, current-library opening, and credential delivery. Start with [Vault](../Sources/AskKeyVault/Vault.swift), [VaultStore](../Sources/AskKeyVault/Storage/VaultStore.swift), and [VaultBootstrap](../Sources/AskKeyVault/Migration/VaultBootstrap.swift). |
| `AskKeySystem` | Bounded external process execution, interactive request transport, cancellation, and operation events. Start with [RestrictedProcess](../Sources/AskKeySystem/RestrictedProcess.swift). |
| `AskKeyIntegrations` | User-level Codex, Cursor, and Grok CLI configuration, safe file transactions, helper verification, and discovery Hook setup. Start with [CodexUserMCPAdapter](../Sources/AskKeyIntegrations/CodexUserMCPAdapter.swift), [CursorUserMCPAdapter](../Sources/AskKeyIntegrations/CursorUserMCPAdapter.swift), and [GrokCLIAdapter](../Sources/AskKeyIntegrations/GrokCLIAdapter.swift). |
| `AskKeyAppKit` | SwiftUI/AppKit views, management sessions and authentication, approval presentation, client onboarding, and application services. Start with [AskKeyApp](../Sources/AskKeyAppKit/App/AskKeyApp.swift), [AppDelegate](../Sources/AskKeyAppKit/App/AppDelegate.swift), and [VaultViewModel](../Sources/AskKeyAppKit/VaultViewModel.swift). The localization catalog is [Localizable.xcstrings](../Sources/AskKeyAppKit/Resources/Localizable.xcstrings). |
| `AskKeyApp` | Production executable entry point, delegating to `AskKeyAppKit`: [AskKeyAppEntry](../Sources/AskKeyApp/AskKeyAppEntry.swift). |
| `AskKeyHelper` | The `askkey` executable: CLI parsing, MCP stdio, discovery Hooks, and Broker forwarding. Start with [main.swift](../Sources/AskKeyHelper/main.swift) and [AgentUsageGuide](../Sources/AskKeyHelper/AgentUsageGuide.swift). It has no Vault dependency. |
| `AskKeyTestSupport` | Test-only E2E runtime configuration, synthetic fixtures, and UI observers under [Tests/AskKeyTestSupport](../Tests/AskKeyTestSupport). It is linked by tests and the E2E application. |
| `AskKeyE2EApp` | Test-only executable that configures the isolated runtime before entering the shared application code: [AskKeyE2EAppEntry](../Tests/AskKeyE2EApp/AskKeyE2EAppEntry.swift). |

The manifest also defines `AskKeyUnitTestSupport` under [Tests/AskKeyUnitTestSupport](../Tests/AskKeyUnitTestSupport) for shared unit-test environment setup. Test support belongs under `Tests`; production targets must not depend on it.

## Allowed dependency directions

The table lists allowed direct dependencies on other local targets. External libraries and Apple frameworks are omitted.

| Production target | Allowed local dependencies |
| --- | --- |
| `AskKeySystem` | None |
| `AskKeyBrokerC` | None |
| `AskKeyBroker` | `AskKeyBrokerC` |
| `AskKeyVault` | `AskKeySystem`, `AskKeyBroker` |
| `AskKeyIntegrations` | `AskKeySystem`, `AskKeyBroker` |
| `AskKeyAppKit` | `AskKeyVault`, `AskKeySystem`, `AskKeyIntegrations`, `AskKeyBroker` |
| `AskKeyApp` | `AskKeyAppKit` |
| `AskKeyHelper` | `AskKeyBroker` |

The checker evaluates the SwiftPM manifest with `swift package dump-package` and scans Swift imports, ignoring comments and string literals. It rejects forbidden edges, missing direct dependencies for local imports, unknown local modules, missing production targets, and unowned source files. Test-only targets rooted under `Tests` are outside its production graph, but importing one from a production target is still forbidden. `AskKeyVault` uses GRDB; the table describes local target edges only.

In the test graph, `AskKeyTestSupport` depends on `AskKeyAppKit`, `AskKeyVault`, `AskKeySystem`, and `AskKeyBroker`. `AskKeyE2EApp` depends on `AskKeyAppKit` and `AskKeyTestSupport`. [The release-symbol check](../scripts/check_release_symbols.sh) verifies that the production application binary contains no forbidden E2E symbols or strings.

## Management and storage

The management window uses [VaultViewModel](../Sources/AskKeyAppKit/VaultViewModel.swift) and [SessionPolicy](../Sources/AskKeyAppKit/SessionPolicy.swift) to coordinate human access. [ManagementAuthenticationProcess](../Sources/AskKeyAppKit/ManagementAuthenticationProcess.swift) provides the system-authentication boundary. Vault operations enforce the management session and any operation-specific authentication before changing or revealing credentials.

[VaultStore](../Sources/AskKeyVault/Storage/VaultStore.swift) owns database access. [VaultCrypto](../Sources/AskKeyVault/Crypto/VaultCrypto.swift) protects payloads, and [CredentialRecordAuthentication](../Sources/AskKeyVault/Crypto/CredentialRecordAuthentication.swift) authenticates record contents and metadata. [AppKeyStore](../Sources/AskKeyVault/Keychain/AppKeyStore.swift) and [KeychainStore](../Sources/AskKeyVault/Keychain/KeychainStore.swift) keep key handling on the application side. The helper cannot open this storage through its module dependencies or public protocol.

Management access, pausing Agent access, and each credential's Allow / Ask / Hidden permission are separate states. Ask is the default; Hidden credentials are omitted from the Agent catalog. Groups organize credentials and do not grant permission. [AgentAccessGate](../Sources/AskKeyVault/AgentAccessGate.swift) coordinates Agent reads with exclusive library changes.

## Approval and delivery

1. The helper submits an explicit credential selection, command, working directory, environment, stable operation ID, and caller declarations to the Broker. Catalog metadata guides selection; names and usage instructions are user data rather than authority to expand an Agent's task.
2. [Vault credential delivery](../Sources/AskKeyVault/Vault+CredentialDelivery.swift) checks authenticated records, visibility, permission, expiry, and delivery mappings. Ask requests bind approval to the operation and complete payload. The application presents them through [AppDelegate approval handling](../Sources/AskKeyAppKit/App/AppDelegate+Approval.swift).
3. Approval alone does not execute a pending request. An identical retry consumes approval; the CLI's `--wait-for-approval` mode performs that continuation in the same helper process. Denial, cancellation, expiry, or a changed payload prevents continuation.
4. [TextRuntime](../Sources/AskKeyBroker/TextRuntime.swift) starts the non-PTY target with approved text in mapped environment variables and file paths in the mappings for file components. [FileDeliveryManager](../Sources/AskKeyVault/FileDeliveryManager.swift) manages temporary-file lifetime and cleanup. Components with delivery `none` are not injected.

CLI stdout and stderr come from the target through passed descriptors. MCP `run` discards target stdout and stderr and returns execution or approval status. A target can itself expose the data it was approved to receive; the Broker's response boundary does not sanitize a target's output.

[RuntimeOperations](../Sources/AskKeyBroker/RuntimeOperations.swift) prevents duplicate execution and replays completed status during the current App runtime, without replaying output. An unknown outcome or App restart requires checking what happened before starting a new operation. `request_cancel` cancels an approval ticket; active execution cancellation uses the socket/control descriptor and process-group cleanup.

Agent create, modify, and delete requests also require approval of frozen submitted material. [Vault write freezing](../Sources/AskKeyVault/Vault+AgentWriteFreeze.swift) and [BrokerFileWriteCoordinator](../Sources/AskKeyBroker/BrokerFileWriteCoordinator.swift) keep review and commit bound to that material. Human-only permissions, groups, settings, permanent deletion, and plaintext management do not become public MCP capabilities.

## Startup and library adoption

[AppDelegate broker lifecycle](../Sources/AskKeyAppKit/App/AppDelegate+BrokerLifecycle.swift) validates installation topology and calls `Vault.prepareAgentRuntime()` before starting the public socket. Invalid installation, storage, or runtime state keeps the Broker unavailable and gives the application a recovery path. Preparing background Agent access does not grant a human management session.

[VaultBootstrap](../Sources/AskKeyVault/Migration/VaultBootstrap.swift) opens the App-owned current library. The runtime database is named `credentials-v2.db`; it is not a repository file. Existing libraries are checked for supported migration history, schema, and authenticated records. [CurrentLibrarySnapshot](../Sources/AskKeyVault/Storage/CurrentLibrarySnapshot.swift) validates a temporary copy of the database and WAL, detects changes to the original, and rejects unsafe file states before opening the actual store. The original is checked again during opening; preflight alone is insufficient.

For first creation, bootstrap writes a complete database under a temporary creation name, publishes it with an exclusive rename, synchronizes the database and directory chain, and only then promotes the pending key. Recovery with a pending key is limited to a database matching unfinished first creation. An existing App key is authoritative; missing databases, missing keys, unsupported schemas, and invalid records do not trigger a replacement empty library.

Current adoption tests are [CurrentLibraryAdoptionTests](../Tests/AskKeyVaultTests/CurrentLibraryAdoptionTests.swift), [CurrentLibraryOpeningRaceTests](../Tests/AskKeyVaultTests/CurrentLibraryOpeningRaceTests.swift), and [VaultBootstrapDurabilityTests](../Tests/AskKeyVaultTests/VaultBootstrapDurabilityTests.swift). Historical upgrade workflows and cloud backup are outside the current v0.1 feature set; see [the feature inventory](features.md).

Protocol version and database schema have separate compatibility checks. A module split does not authorize changing either. Use the actual Vault, Broker, or App lifecycle entry points with temporary stores and synthetic values when testing these boundaries.
