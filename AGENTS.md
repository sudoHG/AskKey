# AGENTS.md

This file is the single source of rules for every agent working in this repository (Codex, Claude, or any other). `CLAUDE.md` only imports it.

## Project

AskKey is a macOS app that stores credentials locally and lets AI agents use them only through a restricted helper (`askkey`) and a local broker inside the app. Each credential has one agent permission: Allow, Ask (default), or Hidden. Agents never receive stored plaintext in broker responses; approved values are delivered to a target process or a short-lived file.

The project started as a fork of [Lokalite](https://github.com/RubenGlez/lokalite) (MIT). It has since diverged substantially; upstream is credited in `LICENSE` and `NOTICE` only.

## Current status: normalization

The codebase is being re-imported from a private legacy repository and restructured. Tracking issue: the pinned "Normalization roadmap" issue. Until that issue is closed:

- All work happens through GitHub Issues and pull requests. See [docs/agents/issue-workflow.md](docs/agents/issue-workflow.md).
- Structural tasks are **move-only**: no logic changes unless the issue explicitly asks for them. If you find a bug, open a new issue instead of fixing it in place.
- iCloud backup and recovery are being removed from v0.1 (Phase 3). Do not extend them.
- Supported agent clients are Codex, Cursor and Grok CLI. Multica support was removed in #17; do not reintroduce it.

## Roles

| Role | Does | Does not |
|---|---|---|
| Planner (Claude) | Writes task issues, reviews PRs, merges, advances phases | Large implementation work |
| Executor (Codex) | Claims `ready-for-agent` issues, implements in a dedicated worktree, opens PRs with a receipt, addresses review comments | Merge PRs, push to `main`, change repository settings |
| Maintainer | Makes decisions, completes `ready-for-human` issues, starts executor sessions | — |

## Safety boundaries (all agents)

Never, unless an issue labeled `ready-for-human` is being done by the maintainer in person:

- Read or write production data in `~/Library/Application Support/AskKey`. Development namespaces are fine: the `dev` subdirectory `~/Library/Application Support/AskKey/dev` (default for Debug builds and `swift test`), `~/Library/Application Support/AskKey Dev` (used by `make run`), and temporary directories.
- Touch `/Applications/Ask Key.app`, or install anything into `/Applications`.
- Read or write the production keychain service `com.sudohg.askkey.vault`. Development builds use `com.sudohg.askkey.vault.dev`.
- Use real credentials in tests. Use synthetic values only.
- Merge PRs, push or force-push `main`, delete branches you did not create, or change repository settings, labels or protection rules.
- Push to or modify the archived repository `sudoHG/AskKey-legacy`. Reading it locally as a reference is fine.

## Product identifiers (do not change)

Bundle ID `com.sudohg.askkey.app`, keychain service `com.sudohg.askkey.vault`, data directory `AskKey`, command `askkey`, MCP server name `askkey`, URL scheme `askkey://`, broker protocol version. Official install path is `/Applications/Ask Key.app` with the helper at `Contents/Helpers/askkey`.

Releases are disabled. Do not add signing, notarization, Sparkle or Homebrew release configuration unless an issue asks for it. Never reuse Lokalite's signing team, Sparkle keys or release entries.

## Repository hygiene

- **No process records in the repo.** Logs, screenshots, xcresult bundles, audit notes and progress journals go to `~/Coding/AskKey-workspace/evidence/<issue-number>/`. Progress is reported in the PR description.
- No absolute local paths (`/Users/...`, `/private/var/...`) in committed files. Use `FileManager` temporary directories in tests.
- File and directory names are English.
- Code, comments, docs and ADRs are written in English. User-facing UI strings live in `Localizable.xcstrings` (English and Simplified Chinese).
- Test fixtures, E2E hooks, probes and debug observers do not belong in `Sources/`. (Being enforced progressively during normalization.)
- Source files stay under 600 lines; `Localizable.xcstrings` is exempt. (Being enforced progressively during normalization.)
- No new third-party dependencies without an issue that approves them.

## Build and test

Requirements: macOS 14+, full Xcode with a Swift 6 toolchain, at least 80 GiB free on the data volume.

```bash
swift build
swift test
```

Push a task branch only after the local Acceptance passes. While the repository is private, CI minutes are scarce: never use GitHub CI as a substitute for local builds or tests. If local resources are busy, wait.

Run tests exactly like CI: do not set `ASKKEY_DEBUG_RUN_DIRECTORY`, `ASKKEY_BROKER_SOCKET` or other `ASKKEY_*` variables unless an issue says so. Several tests rely on the default runtime path resolution.

Run the development app only when an issue needs it; it uses the isolated `AskKey Dev` namespace. Never copy a development build to `/Applications/Ask Key.app`.

## Where to read next

- [docs/agents/issue-workflow.md](docs/agents/issue-workflow.md): claiming, receipts, review
- [docs/agents/triage-labels.md](docs/agents/triage-labels.md): label meanings
