# Changelog

Notable changes to AskKey are documented here, grouped by release and change type.

## [0.1.0] - Unreleased

### Added

- Local encrypted storage for text and file credentials, including credentials with multiple components and environment variable mappings.
- Credential-wide **Allow**, **Ask** (default) and **Hidden** agent permissions.
- Approval for one operation or a revocable timed read allowance; agent writes require approval for each operation.
- Runtime delivery to a target process through environment variables or short-lived private files, without returning stored plaintext in AskKey's agent responses.
- MCP and discovery Hook setup for Codex, Cursor and Grok CLI.

### Known limitations

- No backup or recovery. Keep the originals of your credentials elsewhere.
- No automatic updater. Check GitHub Releases for new versions.
- macOS 14 or later only.
- An approved target can print, copy or forward what it receives.
- Caller names and purposes are declared by the agent and are not verified identity.
- Another process running as the same macOS user may be able to read material after approved delivery. Hidden excludes a credential from the agent catalog but does not defend against that.
- A timed allowance covers the credential for the whole local user, not one agent client.
