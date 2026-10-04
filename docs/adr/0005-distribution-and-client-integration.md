# ADR 0005: Bundled helper and supported client adapters

## Status

Accepted for current topology and client integration. Release publication is governed by [ADR 0006](0006-release-process.md); legacy ADR 0030's signing, notarization and updater roadmap does not establish a shipped release process.

## Context

AskKey is a macOS 14+ App with a restricted helper and local Broker. [Issue #17](https://github.com/sudoHG/AskKey/issues/17) fixes the supported client set as Codex, Cursor and Grok CLI. [AGENTS.md](../../AGENTS.md) preserves product identifiers and requires a separate issue for release configuration.

## Decision

- Keep bundle ID `com.sudohg.askkey.app`, command/MCP server name `askkey`, URL scheme `askkey://` and the existing Broker protocol version. The canonical official topology is `/Applications/Ask Key.app` with `Contents/Helpers/askkey`; this is a product contract, not permission to install a development build there.
- Package the helper with the App. It exposes MCP stdio, Broker transport, explicit runtime delivery and approved write forwarding, health/version/status, discovery hooks and opening the host App. It owns neither vault keys nor direct database access and provides no independent credential-management interface.
- Preserve [official topology checks](../../Sources/AskKeyBroker/OfficialInstallTopology.swift) and [helper signature/resource-seal checks](../../Sources/AskKeyIntegrations/HelperCodeSignatureTrust.swift). A relocated, renamed or mismatched official bundle fails closed. Isolated development uses separate storage, keys, preferences and socket namespaces.
- Use separate adapters for Codex, Cursor and Grok CLI with the same Broker authorization model. Codex manages user `config.toml` through its validated CLI/configuration contract; Cursor manages user `mcp.json`; Grok CLI manages its user `config.toml` and performs bounded diagnostics with isolated state. Do not rewrite unselected project configuration.
- Onboarding checks run only after explicit user action. Before writing, validate the selected client's version/capabilities, authoritative configuration, regular-file/ownership safety and format; preview and freeze the plan, then authenticate. Create controlled rollback material, replace atomically, read back and verify helper identity/tools and Broker health. On failure restore only the owned change, preserving unrelated or concurrent edits; expose recovery action if rollback fails.
- Discovery hooks prompt catalog consultation and have their own readiness state; configuration presence is not verified connectivity or authorization. Real supported-client verification remains separate from synthetic tests.
- Keep production and E2E executables separate as decided in [issue #46](https://github.com/sudoHG/AskKey/issues/46): `AskKeyE2EApp` explicitly installs test support, while `AskKeyApp` uses production defaults. CI checks release symbols and runs required desktop flows in an isolated test bundle. Synthetic CI evidence does not certify a formal release or real-credential client acceptance.
- This ADR adds no release process. Signing, notarization and publication follow [ADR 0006](0006-release-process.md); updater and package-manager work need a separate approved issue. Any future App Store distribution requires its own sandbox feasibility decision rather than weakening the Broker/helper contract.

Current evidence includes the [Codex adapter](../../Sources/AskKeyIntegrations/CodexUserMCPAdapter.swift), [Cursor adapter](../../Sources/AskKeyIntegrations/CursorUserMCPAdapter.swift), [Grok CLI adapter](../../Sources/AskKeyIntegrations/GrokCLIAdapter.swift), [MCP verification contract](../../Sources/AskKeyIntegrations/MCPHelperContract.swift), [onboarding coordinator](../../Sources/AskKeyAppKit/AgentOnboardingCoordinator.swift), [production entry](../../Sources/AskKeyApp/AskKeyAppEntry.swift) and [E2E entry](../../Tests/AskKeyE2EApp/AskKeyE2EAppEntry.swift). Legacy ADR 0030 supplies the bundled-helper and adapter boundaries; current rules and #17/#46 supersede its removed client and release assumptions.

## Consequences

Client setup is a reversible configuration transaction, not a new permission layer. Successful setup requires verified helper/Broker behavior, while unsupported versions, unsafe files or changed plans require explicit repair. The official path and trust boundary remain stable without claiming a public release, production install or completed real-client release gate.
