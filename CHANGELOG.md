# Changelog

Notable changes to AskKey are documented here, grouped by release and change type.

## [Unreleased]

## [0.4.0] - 2026-10-28

### Added

- Read approval Details lists component names and delivery mappings. Write Details distinguishes replaced, unchanged and storage-only items, shows complete before/after instructions with changes marked, and explains group merges and effects on Hidden credentials.
- Clicking an approval reminder opens Pending requests; clicking an expiry reminder opens the matching credential after management unlocks. Notification clicks preserve unsaved edits, confirmations and searches, bringing management forward without navigating away.

### Changed

- MCP `run` now requires an explicit absolute `cwd`, which is shown in approval and used for execution. Callers that omitted it must pass the directory they want the command to run in; missing or relative directories are rejected with a `next_step`. CLI `run` continues to use the terminal's current directory.
- Component names, kinds and delivery mappings are stored as separately encrypted metadata. Catalogs, management lists and unrevealed approvals use this metadata without decrypting stored values; values are opened for explicit authenticated reveal, approved edits or authorized delivery.
- Approval card subtitles state when stored values can't be recovered and how many Hidden credentials a change affects; consecutive identical moves are summarized in one line.
- Approval cards keep their title and action buttons visible on short screens, scroll long Details and warnings, and refit when the display changes. While a file picker is open, requests update the pending count and reminder immediately; the approval prompt waits until the picker closes.
- The Dock icon stays visible during management dialogs, file pickers and alerts. If an approval or write-failure notification cannot be delivered, a Dock reminder remains without taking focus.

### Fixed

- Cancelling Touch ID ends only that request's authentication. Approvals distinguish cancellation from failure, and later requests can authenticate normally; management, settings and setup cancellations close quietly.
- Agent writes using a name already visible in the catalog return `credential_name_conflict` with recovery guidance. Names unavailable to the agent go through approval before any commit failure, without disclosing Hidden names.
- The Agent access sample prompt chooses an active, visible, unexpired credential that can be delivered to a program; when none is available, it offers to create one.
- Claude Code setup detects globally disabled hooks and recognizes only Ask Key's own hook commands. After an MCP configuration write times out, it checks what was saved and requires a fresh connection check instead of retrying an uncertain write.
- Approval text selection, Copy, drag, Services, Share and accessibility preserve the original text, including characters used in names and values, despite display-only wrapping and escaping. Long names and Chinese phrases wrap more clearly.
- Historical credential mappings that block metadata migration can be repaired in the editor, including invisible trailing whitespace. Delivery Options stays open during correction. Oversized approved edits explain the complete credential's 5 MiB limit and keep the previous contents unchanged; capacity errors have separate guidance.

### Security

- The component-metadata completion marker uses HMAC-SHA256 under an HKDF-derived key in a separate authentication domain. Invalid or missing completion state pauses Agent access while keeping management available; this does not detect restoring a whole older library.
- Read approvals and timed allowances are bound to component metadata, which is checked against decrypted components before delivery. Write approvals bind the authenticated stored row before committing the approved edit.

### Upgrade notes

- Before updating, quit Ask Key and back up the library folder at `~/Library/Application Support/AskKey`. Keep the originals of your credentials elsewhere too; Ask Key has no built-in backup or recovery.
- On first launch, the library migrates once, including Hidden and recycled credentials. Credentials and permissions are kept, and valid 0.3.2 Agent access settings are preserved without a Resume step.
- A migrated library cannot be opened by 0.3.2; there is no reverse migration.
- If a credential cannot be migrated, management stays available and names it after unlock. Fix it in the editor or permanently delete it from the Recycle Bin, then reopen Ask Key. Agent access stays off until the migration completes.
- MCP clients must pass an absolute `cwd` to `run`, including when resuming an approval. CLI `run` still uses the terminal's current directory.

## [0.3.2] - 2026-10-21

### Security

- Agent-access settings are stored in the App-only login keychain and authenticated with the App key. Missing, invalid or conflicting policy pauses Agent access until system-authenticated recovery succeeds.
- New vaults generate fresh keys instead of adopting existing pending keys.
- Agent requests, approval decisions and final delivery revalidate agent-access policy and Broker ownership across processes; stricter settings remain in force.

### Changed

- One Ask Key process serves each library. Opening the app again activates the running instance; opening another copy reports that a copy is already running.
- When Agent access is paused, agents are told to ask you to resume it.

### Fixed

- The management window no longer leaves an empty strip along its bottom edge.

### Upgrade notes

- Quit the running app before replacing it with this version.
- On the first launch after updating an existing library, Agent access is paused. Choose **Resume Agent Access** and complete system authentication to continue; credentials and their permissions are kept.
- Resume restores the agent-access defaults: read approvals require authentication, timed allowance is enabled, and its duration is 30 minutes. Review **Settings** afterwards to restore your preferences.
- Keys outside the login keychain or duplicate Keychain items require the [manual repair in the feature guide](docs/features.md#resolving-a-keychain-conflict-after-an-update).

## [0.3.1] - 2026-10-11

### Fixed

- An open approval prompt is brought forward on the current display after time away; new prompts open on the display under the pointer.
- Pressing Esc dismisses the current approval prompt and shows the next pending request.
- Unanswered requests are recorded as expired instead of denied, and expiry is rechecked after wake or unlock.

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
