# ADR 0009: Codex discovery hook as a command hook

## Status

Accepted for v0.2 (#152). Replaces the Codex discovery-hook definition described in [docs/client-integrations.md](../client-integrations.md); the MCP configuration, Broker protocol, permissions and approval model are unchanged.

## Context

Codex is the only supported client whose discovery hook is an `mcp_tool` handler (server `askkey`, tool `credential_discovery_guard`, `PreToolUse`, three-second timeout). The guard keeps its turn state inside the long-lived MCP helper process. Claude Code, Cursor and Grok CLI use command handlers that run `askkey hook <client>` and keep short-lived state in [DiscoveryTurnStore](../../Sources/AskKeyHelper/DiscoveryTurnStore.swift).

Codex requires explicit trust for each hook definition hash. When Codex is launched by Orca, Orca copies hook trust into its per-account runtime home, but its synchronization only recognizes command handlers and then prunes trust entries it did not recognize. The AskKey `mcp_tool` hook therefore loses its trust in every new Orca-managed session, and the user is asked to trust it again. The investigation in #152 reproduced the pruning logic in isolation and verified that standalone Codex keeps the trust across restarts.

## Decision

- **Command hook for Codex.** The Codex discovery hook runs the signed helper as a command handler: `"/Applications/Ask Key.app/Contents/Helpers/askkey" hook codex`. Its events, matcher and payload fields follow Codex's actual command-hook contract for the supported version, established from Codex's own source or an isolated real Codex before any parser is written. The behavior matches the other command-hook clients: an SSH connection through the shell tool is denied with the shared reminder until a `list_credentials` call settles in the same session and turn, with the existing 30-second no-progress release. The hook never runs tool input, never reads credentials and never grants access.
- **Trust stays explicit.** Setup keeps the existing native app-server flow: write the hook to `~/.codex/hooks.json`, then enable and trust only the new definition's current hash through `config/batchWrite`, and verify it with `hooks/list`. The old hash is never reused and hook trust is never bypassed.
- **Migration of the exact legacy definition only.** An exact AskKey-owned `mcp_tool` group is replaced by the new command handlers in one write, with the existing backup, concurrent-edit detection and readback. Customized or duplicated definitions are reported, not rewritten. Unrelated hooks and disabled choices are preserved.
- **The `credential_discovery_guard` MCP tool stays** for configurations that have not been migrated; onboarding no longer requires it. Removing it needs its own issue.
- AskKey does not detect Orca, edit Orca's runtime homes or depend on an upstream Orca change.

## Consequences

All four clients share one discovery mechanism and the same timeout semantics. Users with the legacy definition must trust the new hook once. Whether Orca-managed sessions keep that trust is verified on the maintainer's Mac with the installed release (#127); unit tests and isolated Codex checks cannot establish it.
