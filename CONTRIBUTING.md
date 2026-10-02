# Contributing to AskKey

AskKey is under active restructuring before its first public release. Read the [feature inventory](docs/features.md) and use a scoped GitHub issue to agree on the intended change. Agent contributors must also follow [AGENTS.md](AGENTS.md) and the [issue workflow](docs/agents/issue-workflow.md).

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

For desktop UI changes, run the required UI flows when the task calls for them:

```bash
bash scripts/run-e2e.sh
```

The script builds a separate E2E application and creates isolated synthetic runtime data. It requires XcodeGen and a macOS desktop session. Review the generated report: incomplete, failed or skipped required flows do not count as a passing result. Do not substitute the installed application or real client credentials for the test fixtures.

Check repository hygiene before submitting a pull request:

```bash
python3 scripts/check_hygiene.py
```

The checker compares tracked files with a shrinking baseline. Stage new files before running it so they are included. Do not add baseline exceptions to hide new violations. Change the baseline only when the issue authorizes it; an approved cleanup may remove existing entries, not add new ones.

## Changes and evidence

Keep changes within the issue's scope. Structural tasks are move-only unless the issue explicitly permits behavior changes; preserve every Keep behavior in the feature inventory. Write code, comments and documentation in English. Put user-facing English and Simplified Chinese strings in `Localizable.xcstrings`. New third-party dependencies require an issue that approves them.

Process records never belong in the repository: logs, screenshots, result bundles, audit notes and progress journals must be kept in the external evidence workspace described in [AGENTS.md](AGENTS.md). The UI runner produces ignored output; move evidence outside the checkout before delivery and never include generated records or sensitive data in a commit. Report progress and validation in the pull request description.

## Pull requests

Use the [pull request template](.github/PULL_REQUEST_TEMPLATE.md). Link the task issue and fill every section, using "None" where appropriate:

- Summary of the problem and resulting behavior.
- Diff stat and the paths changed.
- Test commands, passed/failed/skipped counts and comparison with `main`.
- Results of the issue's other acceptance checks.
- Deviations and questions for review.

Keep the receipt grounded in commands you actually ran. Explain omitted checks instead of claiming a pass. Address review comments in the same task branch and update the receipt after changes.

For suspected vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of posting details in a public issue.
