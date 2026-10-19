# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository: open the **Security** tab, then select **Report a vulnerability**. You can also open the [private report form](https://github.com/sudoHG/AskKey/security/advisories/new).

Please keep security reports private rather than opening a public issue or pull request. Include:

- The affected commit on `main`, macOS version and relevant agent client/version.
- A description of the security boundary that failed, the expected behavior and the potential impact.
- Minimal reproduction steps using synthetic credentials and isolated test data.
- Relevant, sanitized error messages or logs, with sensitive values and identifying details removed.

Never include real credentials, recovery material, vault contents or client configuration contents, even in a private report. Use synthetic replacements in examples and inspect attachments before submitting them.

## Supported versions

Security reports are supported for the [latest GitHub Release](https://github.com/sudoHG/AskKey/releases/latest) and `main`.

## Security boundaries

- Credentials are encrypted locally. Agents request access through the restricted `askkey` helper and the App's local Broker. **Allow**, **Ask** (the default) and **Hidden** are credential-wide permissions; Allow still requires Broker-mediated delivery.
- AskKey's management, MCP and helper responses do not return stored credential plaintext. Approved text values go to the selected target process; file values use short-lived private files. An approved target can print, copy or forward the material it receives.
- Caller-provided names, paths, signatures and purposes are display context, not verified identity or authorization. A timed read allowance applies globally to one credential for the local macOS user; it does not isolate one agent client from other programs running as that user.
- AskKey does not guarantee that another process running as the same macOS user cannot inspect or copy material after approved delivery. Hidden excludes a credential from the Agent catalog and access requests, but does not defend against same-user side channels.
- Approval is bound to the requested operation and frozen payload. Agent writes require a separate approval and commit the frozen content atomically; approval cannot be reused for a different operation or changed payload.
- Revocation, expiry and pause prevent delivery that has not passed the final launch authorization check and trigger temporary-file cleanup. They cannot retract material already received by a target. Agent access can be paused while management is locked or closed; resuming access requires system authentication and does not unlock management.
- One Ask Key process serves each library namespace. Before opening the vault, the App holds a private exclusive file lock for its lifetime; another launch activates the running instance and exits. Development and production libraries have separate locks. The Broker refuses a live socket and removes its socket on shutdown only while the path retains the device and inode it bound.
- Agent-access policy changes take effect across processes at the next agent request. Catalog requests, approval decisions (also after system authentication), agent commits and the final delivery/spawn boundary re-read and verify the Keychain policy. The stricter persisted or in-memory policy wins: either pause blocks access, either authentication requirement is enforced, either disabled timed allowance disables it, and the shorter duration applies. Adopting a stricter policy cancels requests and approvals and cleans up deliveries. Denial remains available when policy verification fails; an already-cancelled request stays cancelled. Settings saves, pause and resume re-read policy under the exclusive gate rather than writing a stale cache. A removed lock file does not bypass these policy checks.
- The agent-access policy (pause, read-approval authentication and timed-allowance settings) lives in the fixed login keychain file under the same App-only access control as the vault key and is authenticated with the App key. Vault, pending, legacy and policy operations are pinned to that file, independently of the default keychain or search-list preferences; duplicate or outside-keychain items are rejected. Each policy save deletes the previous item, adds a fresh App-only item and verifies its value. An interrupted replacement can leave the policy missing.
- Without an App key, AskKey discards any existing pending key and generates a new key; a library whose contents exactly match first creation is discarded and recreated, unless this Vault still holds its open store. While no App key exists and the library has no credential rows (before first creation, after a local erase, or after an interrupted creation), a same-user process that plants an App key, alone or together with an empty supported library, can choose the key.
- A missing or invalid policy pauses agent access, requires read-approval authentication and disables timed allowances until system-authenticated resume restores defaults. Only verified first creation initializes defaults after key promotion; an existing library with an App key fails closed even when it has no credential rows. Libraries predating this policy take the recovery path once after updating. A failed pause, settings or Resume save keeps agent access paused in this process with a persistent notice that distinguishes an unchanged policy from an unknown persisted state. Reopening retries a pending pause save only when a valid policy was loaded and recovery has never been latched in this process; recovery prevents all retry writes. Reopening cannot clear pause intent or recovery; only a successfully saved, system-authenticated Resume clears these latches. An unsaved pause may be lost when the App restarts. Successful authenticated local erase resets the latches for a new library.
- Replacing the whole library database with an older copy is not detected, an existing credential-history rollback limitation; the current policy remains in the Keychain. Replacing the whole login keychain file is not detected either. An older signed Ask Key build that can read the vault key is not bound by this policy.

The [feature inventory](docs/features.md) records the retained behaviors and planned removals during restructuring. Report a suspected violation of these boundaries privately, including when the observed behavior differs from that inventory.
