# Changelog

Notable changes to AskKey are documented here, grouped by release and change type.

## [0.3.0] - 2026-10-09

### Added

- Agents can write a credential's usage instructions and group when they create or modify it through `create_credential` and `modify_credential`, including changes to only the instructions or group. A group name that does not exist yet is created when the write is approved. The approval shows the instructions and the group in full.
- `organize_credentials`: agents can move credentials and create, rename or delete groups in one batch of up to 64 steps, approved once with one Touch ID. The batch applies completely or not at all. Renaming or deleting a group also covers credentials that agents cannot see, and the approval says how many there are. Deleting a group only ungroups its credentials.
- `list_credentials` shows each credential's group and lists the groups agents can see.
- Each release also publishes `AskKey.dmg` and `AskKey.dmg.sha256`, so `https://github.com/sudoHG/AskKey/releases/latest/download/AskKey.dmg` always downloads the latest version.

### Changed

- The app is named 请旨 on Chinese systems and Ask Key elsewhere, in Finder, Spotlight, Login Items and system prompts. Finder can show the old name until macOS refreshes its cache.
- Approval cards for writes and group changes use the same layout as the read card: one sentence that names the requester, the action and the credential, and one line with the consequence, such as the new group, "the old value can't be recovered", or the Recycle Bin. Everything else is under Details. Irreversible changes use a destructive button, and cancelling Touch ID no longer changes the default button.
- `list_credentials` returns an object with `credentials` and `groups` instead of a bare list. Scripts that parse its output need updating.

### Known limitations

- No backup or recovery. Keep the originals of your credentials elsewhere.
- The approval prompt does not yet list the environment variable names a credential is delivered as (#137).
- All limitations listed for 0.1.0 still apply.

## [0.2.0] - 2026-10-05

### Added

- Claude Code support: AskKey adds itself through the official `claude mcp` CLI at user scope and installs credential discovery hooks in `~/.claude/settings.json`.
- The approval prompt shows the command that will run and its working directory; caller name and purpose are marked as declared by the agent.
- A first-run path: the welcome page leads from the first saved credential to connecting an agent, with a sample prompt to try.
- Credential templates and an import preview that shows permissions before anything is saved.

### Changed

- Permissions are named **Allow**, **Ask every time** and **Hidden**.
- A new visual design across the app: one neutral palette with an accent and a warning color, grouped lists, and the app icon on the welcome page, approval prompt and pending requests.
- Codex discovery now runs as a command hook, like the other clients, so Orca-managed Codex sessions keep its trust. Reconnect Codex once from **Agent access** after upgrading and trust the new hook.
- Access records keep only the executable name of an approved command, never its arguments or working directory.
- Approval prompts appear without bringing the Ask Key window forward, Touch ID prompts accept a finger without an extra click, and focus returns to where you were afterwards.
- The sample prompt on **Agent access** works in any folder and never prints credential values.

### Fixed

- Replacing a credential on import silently kept its old permission while the screen suggested a new one; the screen now shows that the permission is kept.
- Access records described denied and failed requests as if they had happened.
- A pending approval could be left without a prompt when the one before it expired during Touch ID.
- A rare failure when a client command closed its input before AskKey finished writing to it.

### Known limitations

- No backup or recovery. Keep the originals of your credentials elsewhere.
- The approval prompt does not yet list the environment variable names a credential is delivered as (#137).
- All limitations listed for 0.1.0 still apply.

## [0.1.0] - 2026-10-04

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
