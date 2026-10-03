# Client integration guide

AskKey supports Codex, Cursor, and Grok CLI. Each client launches the local `askkey` MCP stdio helper; permission, approval, and credential delivery remain in the macOS application's Broker. Client-side tool approval can add restrictions, but does not replace AskKey approval.

This guide describes the current adapters and onboarding flow. It is a source guide, not a guarantee that any future client version supports the same configuration or Hook API. See [Architecture](architecture.md) for module boundaries and [Testing](testing.md) for isolated verification.

## Shared setup contract

The MCP server name is `askkey`, and its arguments are `mcp`. The official runtime helper location is `/Applications/Ask Key.app/Contents/Helpers/askkey`, an installed path outside the repository. [OfficialInstallTopology](../Sources/AskKeyBroker/OfficialInstallTopology.swift) resolves the helper and rejects an invalid official installation. Development and E2E builds use their isolated application and configuration locations.

The application checks existing configuration and computes a plan before writing. Onboarding rechecks the plan's preconditions when applying it, so a concurrent edit cannot silently become a different approved write. Unrelated servers, Hook rules, and configuration are preserved. Unsafe paths, malformed content, unsupported client capabilities, or uncertain configuration authority stop automatic setup. The UI shows the client, intended change, result, and next step rather than raw configuration or internal errors.

Configuration includes the helper location and integration settings, never stored credential values or Vault keys. [ClientConfigFileIO](../Sources/AskKeyIntegrations/ClientConfigFileIO.swift) provides shared no-follow reads and atomic publication; each adapter retains its own validation and rollback rules. MCP writes keep a controlled rollback copy until verification succeeds. Backups use private directories and files, normally `0700` and `0600`; successful MCP transactions remove their rollback copy. Discovery and Codex trust writes have separate snapshots, so the multi-step flow must not be treated as one all-or-nothing MCP transaction.

## What setup writes

The paths in this table are user-runtime configuration files, not tracked repository files. The application manages user-level configuration only; it does not write project-level client configuration.

| Client | MCP configuration | Discovery setup |
| --- | --- | --- |
| Codex | `~/.codex/config.toml`, AskKey's `[mcp_servers.askkey]` entry. The existing TOML transaction preserves unrelated content and verifies readback. | Add the standard AskKey `PreToolUse` MCP-tool Hook to `~/.codex/hooks.json`. Through native app-server `config/batchWrite`, enable and trust only that Hook's current hash in the user configuration. |
| Cursor | Merge `mcpServers.askkey` into `~/.cursor/mcp.json`, preserving other servers and existing file permissions. | Merge the standard command Hook into `~/.cursor/hooks.json` for `preToolUse`, `postToolUse`, and `postToolUseFailure`, preserving other handlers and their order. It invokes the installed helper with `hook cursor`. |
| Grok CLI | Update `[mcp_servers.askkey]` in `~/.grok/config.toml` with the lossless TOML writer, preserving unrelated content. | Create or verify the owned file `~/.grok/hooks/askkey-discovery.json` for `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, and `PostToolUseFailure`. It invokes the installed helper with `hook grok`; unknown customized content is not overwritten. |

The entry points are [CodexOnboardingSetup](../Sources/AskKeyAppKit/CodexOnboardingSetup.swift), [CommandHookOnboardingSetup](../Sources/AskKeyAppKit/CommandHookOnboardingSetup.swift), and [AgentClientConnector](../Sources/AskKeyAppKit/AgentClientConnector.swift). Hook definitions and file handling are in [CodexDiscoveryHookConfiguration](../Sources/AskKeyIntegrations/CodexDiscoveryHookConfiguration.swift), [CommandDiscoveryIntegration](../Sources/AskKeyIntegrations/CommandDiscoveryIntegration.swift), and [CommandDiscoveryHookConfiguration](../Sources/AskKeyIntegrations/CommandDiscoveryHookConfiguration.swift).

Codex MCP setup can use a known official CLI contract as an isolated preflight, followed by the application's preserving TOML write. Native Hook setup separately checks actual app-server capability and user-layer authority. A CLI version check alone cannot establish Hook support. [CodexNativeHookClient](../Sources/AskKeyIntegrations/CodexNativeHookClient.swift) requires the native user layer to identify the expected configuration file and performs a version-checked trust write.

Grok similarly preflights official `mcp add` in isolation when available. The current [Grok apply implementation](../Sources/AskKeyIntegrations/GrokCLIAdapter+Apply.swift) can continue to the lossless writer if that isolated add fails, but rejects a client identified as lacking `--scope`. The real configuration must still pass all subsequent checks. Remote connectors and project-scoped definitions do not satisfy the local user-level AskKey contract.

## How verification works

All three adapters read back the expected server configuration, verify the helper's trust and expected identity, perform MCP `initialize` and `tools/list`, and check Broker health. [MCPHelperContract](../Sources/AskKeyIntegrations/MCPHelperContract.swift) requires the current expected MCP protocol and server identity/version, with at least `list_credentials` and `run`. The Broker protocol is separate from the MCP protocol.

| Client | Additional checks and source |
| --- | --- |
| Codex | Verify enabled MCP configuration, executable non-symlink helper, Broker health and Broker protocol version. Onboarding's MCP verification additionally requires `credential_discovery_guard`. Native `hooks/list` must report the exact standard user Hook enabled and trusted, with the expected source, matcher, handler, and current hash. See [MCP verification](../Sources/AskKeyIntegrations/CodexUserMCPAdapter+Verification.swift) and [native Hook verification](../Sources/AskKeyIntegrations/CodexNativeHookClient.swift). |
| Cursor | Verify configuration, executable trusted helper, MCP handshake/tool list, and Broker health. Separately probe `hook capabilities` for Cursor support and read back the standard Hook configuration. See [MCP verification](../Sources/AskKeyIntegrations/CursorUserMCPAdapter+Verification.swift), [MCP process probe](../Sources/AskKeyIntegrations/CursorUserMCPAdapter+Process.swift), and [command discovery verification](../Sources/AskKeyIntegrations/CommandDiscoveryIntegration.swift). |
| Grok CLI | Require official `mcp list --json` to report the expected non-project stdio server, and `mcp doctor --json askkey` to report it healthy. Verify helper trust, MCP identity/tools, and helper `health` including Broker version. Separately probe Grok command-Hook capability and read back the owned Hook definition. See [Grok verification](../Sources/AskKeyIntegrations/GrokCLIAdapter+Verification.swift). |

Merely finding an `askkey` entry is configuration presence. Adapter-level `connected` means the MCP/helper/Broker checks succeeded. Product-level `verifiedConnected` additionally requires discovery readiness: Codex reports `enabled`, while Cursor and Grok report `configured`. Cursor and Grok readback proves a configuration is ready for a new client task; it does not prove the current client task has loaded or executed the Hook.

Checks run after an explicit user action. Opening the onboarding page does not itself perform a client connection check. After setup, start a new client task. A successful synthetic test proves the tested contract and isolation, not a real client's end-to-end task or credential validity.

## Partial setup, rollback, and cancellation

An existing unhealthy MCP configuration is reported as unverified and is not overwritten as part of discovery repair. A new MCP transaction restores its original bytes and permissions if connection verification fails, subject to its conflict checks. A rollback conflict or failure is reported explicitly; it must not be hidden by writing over a concurrent user edit.

If MCP verification succeeds but Hook setup fails or is cancelled, the verified MCP connection is retained and onboarding remains incomplete. For Codex, a native trust write may have succeeded before its response was lost. The flow reports an uncertain outcome and requires a fresh check before another write, rather than restoring whole user configuration files. See [Codex apply handling](../Sources/AskKeyAppKit/CodexOnboardingSetup.swift) and [command-Hook apply handling](../Sources/AskKeyAppKit/CommandHookOnboardingSetup.swift).

Cancellation is scoped to the active connection operation through [RestrictedProcessCancellation](../Sources/AskKeySystem/RestrictedProcessCancellation.swift). Onboarding can settle the operation and permit retry without declaring an incomplete integration successful.

## Discovery and credential use

Discovery Hooks guide the Agent to query the credential catalog before a direct SSH connection. They never grant credential access. Codex's native Hook has a three-second timeout and can allow the client to continue when unavailable. Cursor and Grok command Hooks stop blocking after 30 seconds without discovery progress; a missing callback is not recorded as successful discovery.

[CommandDiscoveryHook](../Sources/AskKeyHelper/CommandDiscoveryHook.swift) and [DiscoveryTurnStore](../Sources/AskKeyHelper/DiscoveryTurnStore.swift) implement the command-Hook flow. The runtime state retains hashes, timestamps, and completion markers with bounded retention, rather than command text, hostnames, or credential values. Cursor's generic completion name `MCP:list_credentials` has no server identity; a same-named tool can settle its reminder. This state is guidance, not authorization evidence. Grok uses `askkey__list_credentials` and binds events to its session and turn information.

The catalog returns visible metadata and component delivery mappings. An Agent selects the smallest matching credential set and uses the mapping the target program supports. For command output, [AgentUsageGuide](../Sources/AskKeyHelper/AgentUsageGuide.swift) directs it to CLI `run`, preferably with `--wait-for-approval`. MCP `run` discards stdout/stderr and returns status only. Pending approval does not execute automatically; retries preserve the operation ID and complete payload. Client completion, Hook readiness, and an allowed Broker operation are separate claims.

Use synthetic configurations and process fixtures for integration tests. Access to real client accounts, production credentials, or the installed application requires the maintainer's separate authorization under [AGENTS.md](../AGENTS.md). Releases are disabled; current connection checks do not establish signing, notarization, or release acceptance.
