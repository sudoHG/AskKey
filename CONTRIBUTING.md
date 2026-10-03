# Contributing to AskKey

AskKey is being restructured before its first public release. Read the [architecture guide](docs/architecture.md), the [architecture decisions](docs/adr/) and the [feature inventory](docs/features.md), and use a scoped GitHub issue to agree on the intended change. The [documentation index](docs/README.md) lists everything else. If you use an AI agent, it must follow the general rules in [AGENTS.md](AGENTS.md); the issue workflow under `docs/agents/` is the maintainer's internal process and does not apply to outside contributions. Use your own Git identity.

## Requirements

- macOS 14 or later.
- Full Xcode with a Swift 6 toolchain.
- At least 80 GiB free on the data volume before building or running tests.
- Python 3 for repository checks and test automation.
- XcodeGen when running the desktop UI flow script.

## Build and test

From the repository root:

```bash
swift build
swift test
```

Run these commands with the same defaults as CI. Do not set `ASKKEY_DEBUG_RUN_DIRECTORY`, `ASKKEY_BROKER_SOCKET` or other `ASKKEY_*` variables unless the task explicitly requires them; some tests depend on default runtime path resolution. Use synthetic values and isolated test data only. Do not access production credential data or the production keychain, and do not modify the installed application.

CI runs the required desktop UI flows on every pull request. Running them locally takes over the desktop (mouse, keyboard and window focus) for several minutes, so do it only when you need to debug a UI failure:

```bash
bash scripts/run-e2e.sh
```

The script builds a separate E2E application and creates isolated synthetic runtime data. It requires XcodeGen and a macOS desktop session. Review the generated report: incomplete, failed or skipped required flows do not count as a passing result. Do not substitute the installed application or real client credentials for the test fixtures.

Run the repository checks before submitting a pull request. CI runs the first three on every pull request:

```bash
python3 scripts/check_hygiene.py
python3 scripts/check_module_deps.py
bash scripts/check_release_symbols.sh
```

- `check_hygiene.py` enforces fixed rules with no baseline: the 600-line limit for Swift files, no test support in `Sources/`, restricted `#if DEBUG`, no local absolute paths, English file names and English text outside the localization catalog and its approved exceptions. Stage new files before running it so they are scanned.
- `check_module_deps.py` checks imports against the allowed dependency directions in the [architecture guide](docs/architecture.md#allowed-dependency-directions).
- `check_release_symbols.sh` builds the release app and fails if E2E or test-support names appear in the binary.

For a pull request that only moves or splits code, also run `python3 scripts/check_move_only.py origin/main` and include its result. It fails when lines are added that are not type or extension headers.

[docs/testing.md](docs/testing.md) describes every check and test suite in detail.

## Changes and evidence

Keep changes within the issue's scope. Structural tasks are move-only unless the issue explicitly permits behavior changes; preserve every Keep behavior in the feature inventory. Write code, comments and documentation in English. Put user-facing English and Simplified Chinese strings in `Localizable.xcstrings`. New third-party dependencies require an issue that approves them.

Process records never belong in the repository: logs, screenshots, result bundles, audit notes and progress journals are deleted once their results are read. The UI runner writes to an ignored output directory; never commit generated records or sensitive data. Report commands, counts, SHAs and CI links in the pull request description instead.

## Pull requests

Use the [pull request template](.github/pull_request_template.md). Link the task issue and fill every section, using "None" where appropriate:

- Summary of the problem and resulting behavior.
- Diff stat and the paths changed.
- Test commands, passed/failed/skipped counts and comparison with `main`.
- Results of the issue's other acceptance checks.
- Deviations and questions for review.

Keep the receipt grounded in commands you actually ran. Explain omitted checks instead of claiming a pass. Address review comments in the same task branch and update the receipt after changes.

For suspected vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of posting details in a public issue.
