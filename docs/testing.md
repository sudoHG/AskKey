# Testing and acceptance guide

Run the acceptance specified by the task issue and describe the commands actually run in the pull request. [Package.swift](../Package.swift), [the CI workflow](../.github/workflows/ci.yml), and the individual scripts define the current test targets and gates. Historical test counts are not fixed acceptance totals.

## Environment and isolation

Builds and Swift tests require macOS 14 or later, full Xcode with a Swift 6 toolchain, and at least 80 GiB free on the data volume. Python 3 is needed for Automation tests and repository checks. Desktop UI tests also require XcodeGen, `xcresulttool` support for `get test-results`, and an interactive macOS desktop session.

Before a build or test that can invoke Xcode, check free space with `df -h /System/Volumes/Data`. Do not begin another build below the required threshold. If local resources are busy, wait. Do not install platforms or delete another task's data to satisfy the check.

Use synthetic values and temporary stores. Debug builds and ordinary Swift tests use the development namespace selected by [VaultConfiguration](../Sources/AskKeyVault/VaultConfiguration.swift) and [BrokerConfiguration](../Sources/AskKeyBroker/BrokerConfiguration.swift). The isolated development launcher uses a separate development application namespace. Production data, production keychain services, and the installed application are outside test scope; follow [AGENTS.md](../AGENTS.md).

Run ordinary build and test commands with CI defaults. Do not set `ASKKEY_DEBUG_RUN_DIRECTORY`, `ASKKEY_BROKER_SOCKET`, or other `ASKKEY_*` variables unless the issue explicitly requires them. Tests and dedicated isolation scripts manage their own synthetic environment. Changing the shell's runtime overrides can invalidate tests that check default path resolution.

## Local checks

From the repository root, the non-desktop commands in `build-and-test` are:

```bash
swift build
swift test
bash scripts/check_release_symbols.sh
bash scripts/test-cancellation-runtime.sh
python3 -m unittest discover -s Tests/Automation -v
bash scripts/test-dev-launch.sh
python3 scripts/check_hygiene.py
python3 scripts/check_module_deps.py
```

| Check | Coverage and limits |
| --- | --- |
| `swift build` | Compiles the SwiftPM package with the default Debug configuration. Compilation is not behavioral acceptance. |
| `swift test` | Runs the Swift unit and integration targets listed below. It does not run the independent XCUITest desktop suite. |
| [Release-symbol check](../scripts/check_release_symbols.sh) | Builds the release `AskKeyApp` product with one job and inspects both `nm` and `strings` output. Missing binaries, inspection failures, or forbidden E2E symbols/strings fail the check. This is a production/test boundary check, not release signing or publication. |
| [Cancellation runtime check](../scripts/test-cancellation-runtime.sh) | Compiles the real process-cancellation implementation and a synthetic probe at `-Onone` and `-O`, then checks isolation and cleanup. |
| [Automation tests](../Tests/Automation) | Test desktop evidence rejection, request-evidence reading, synthetic Hook probes, and the hygiene, move-only, dependency, and release-symbol checkers. These tests do not create a genuine desktop pass or call a real model. Some compile Swift probes. |
| [Development launcher check](../scripts/test-dev-launch.sh) | Uses a temporary application stub to test isolated development paths, permissions, and rejection of production locations. |
| [Hygiene check](../scripts/check_hygiene.py) | Enforces fixed rules for tracked files: ASCII filenames, no developer-specific absolute paths, a 600-line limit for every `.swift`, `.py`, `.sh`, `.c` and `.h` file anywhere in the repository, no test-support types under production sources, restricted `#if DEBUG`, and removed-client references. Stage new files before running it so they are scanned. There is no baseline file or `--write-baseline` mode. |
| [Module dependency check](../scripts/check_module_deps.py) | Evaluates the manifest and scans production Swift imports against the allowed local graph. See [Architecture](architecture.md). |

For move-only structural tasks, also run:

```bash
python3 scripts/check_move_only.py origin/main
```

[The move-only checker](../scripts/check_move_only.py) compares Swift line multisets under `Sources` and `Tests` by default. Removed meaningful lines must reappear; new type/extension headers and access-only edits are reported separately, while unmatched behavioral additions fail. It does not validate prose, prove full behavioral equivalence, or replace build and test acceptance. List any issue-authorized deviations in the receipt. The CI workflow tests the checker through Automation tests, but does not run this task-specific comparison against a PR base.

## Swift test targets

| Target | Primary coverage |
| --- | --- |
| [AskKeyBrokerTests](../Tests/AskKeyBrokerTests) | Bounded protocol/transport, approval state and consumption, execution/replay, cancellation, file-write staging, and helper behavior. |
| [AskKeyVaultTests](../Tests/AskKeyVaultTests) | Credential storage/authentication, current-library adoption and durability, management and Agent access, frozen writes, file delivery, and local lifecycle. |
| [AskKeySystemTests](../Tests/AskKeySystemTests) | Restricted process execution, bounded transport/output, and cancellation. |
| [AskKeyIntegrationsTests](../Tests/AskKeyIntegrationsTests) | Safe client configuration, preserving writes and rollback, helper trust and protocol, discovery Hooks, and isolated process contracts. |
| [AskKeyAppTests](../Tests/AskKeyAppTests) | App lifecycle, management sessions, approval privacy/presentation, onboarding state/cancellation, localization, and view wiring. |

For a focused iteration, `swift test --filter CurrentLibraryAdoptionTests` selects one behavior area. The final receipt must distinguish focused and full-suite runs. An exit status of zero with no selected tests does not verify the intended behavior. Do not use `--skip-build` after changing the sources being tested.

The ordinary suite has explicit opt-in entries: the isolated file-commit crash subprocess in [FileWriteCoordinatorTests](../Tests/AskKeyVaultTests/FileWriteCoordinatorTests.swift), synthetic fixture generation in [NativeBootstrapFixtureGenerationTests](../Tests/AskKeyVaultTests/NativeBootstrapFixtureGenerationTests.swift), and the installed Codex CLI contract in [CodexCLIContractTests](../Tests/AskKeyIntegrationsTests/CodexCLIContractTests.swift). The installed CLI entry skips unless both `ASKKEY_TEST_CODEX_EXECUTABLE` and `ASKKEY_TEST_CODEX_EXPECTED_VERSION` are explicitly supplied; ordinary CI uses synthetic CLI fixtures. Do not turn these into mandatory real-client runs or set opt-in variables solely to remove skips. Compare actual skip names and reasons with the current base; investigate additional skips rather than copying legacy totals.

## SDK behavior and CI jobs

`Package.swift` explicitly links executable and test targets with the selected Xcode's macOS SDK version while keeping the deployment target at macOS 14.0. Debug link defaults previously recorded SDK 14.0 even when compiling against a newer SDK, which selected AppKit's legacy linked-before behavior. Optimization and development isolation do not change.

`scripts/check_sdk_markers.py <binary>...` prints and checks every architecture's `LC_BUILD_VERSION` against `xcrun --sdk macosx --show-sdk-version`; missing markers, failed inspection and mismatches fail the check. `build-app.sh` checks the app and helper before assembly. App, E2E app, helper and test bundle markers must match the full Release SDK version.

After the suite, CI uses `--test-products <build-products-directory>` to read each `.xctest` bundle's `CFBundleExecutable` when `Contents/Info.plist` exists. Native SwiftPM bundles can omit that plist; those use `Contents/MacOS/<bundle name without .xctest>`. Both paths require an existing file with a Mach-O or fat header before inspecting its SDK markers. Nested dSYM debug-symbol files are excluded; missing bundles, invalid metadata and missing or non-Mach-O executables fail closed.

The actual test main executable is Apple's XCTest agent shipped with the selected Xcode. Its SDK can differ in minor version from that Xcode's current SDK (for example, host 26.4 with SDK 26.5). The test support passes that executable as `--test-host`, requiring the same SDK major and printing both full versions; a missing marker or major mismatch fails closed. Test bundles remain exact matches. The visible-window test checks both before opening a window. This policy does not establish exact AppKit behavior parity across SDK minor versions; the full versions remain visible for pre-release comparison. Raw `swift test` and the Makefile remain the test entry points; Apple's installed agent is never modified.

The two required jobs stay on `macos-latest`: `build-and-test` checks Debug, Release and test binaries, and `basic-ui-flows` uses the same SDK for the isolated E2E app. Both report their toolchain and SDK markers. The additional `release-sdk-window-check` job uses the `xcode-27` public-preview image to compare Debug and Release markers and run the visible management-window lifecycle test. It is informational (`continue-on-error: true`); an unavailable preview runner or a failing preview test must be reported separately from required-job acceptance.

## Desktop flows run in CI

The `basic-ui-flows` job runs `bash scripts/run-e2e.sh` on a clean macOS runner. Maintainer agents must not run it locally: it drives the real mouse, keyboard, window focus, and desktop for several minutes. A local run is permitted only when the issue explicitly requires it or a CI-only UI failure needs local debugging, and only after stating the reason to the maintainer (through Orca, or in the PR when Orca is unavailable) and receiving approval. Read-only examination of CI results does not require taking over the desktop.

[The runner](../scripts/run-e2e.sh) builds the test-only `AskKeyE2EApp` through [build-app.sh](../scripts/build-app.sh), generates the XCUITest project from [Tests/UI/project.yml](../Tests/UI/project.yml), and runs [Tests/AskKeyE2ETests](../Tests/AskKeyE2ETests). It uses a separate E2E identity, ad hoc signing, per-run synthetic state, and controlled process cleanup. It does not install the production application.

[Tests/UI/required-flows.json](../Tests/UI/required-flows.json) currently lists 15 required flows. They cover explicit connection checks, completion feedback, missing discovery, cancellation and retry, denial, one-time approval and replay, pending cancellation, active-helper disconnection, pending-approval invalidation after restart, credential management persistence, and management-window locking. Every required flow must pass with zero failed tests, skips, or expected failures. A subset or zero executed tests is not acceptance.

[e2e-report.py](../scripts/e2e-report.py) generates local receipts from [run-e2e.sh](../scripts/run-e2e.sh), and [e2e-gate.py](../scripts/e2e-gate.py) rereads the original xcresult and checks required names, result consistency, evidence hashes, and a source fingerprint. The fingerprint covers source, tests, scripts, CI workflows, and package inputs; changed inputs invalidate prior evidence. Hand-written result JSON cannot substitute for the original bundle. This detects stale or inconsistent evidence, not maliciously relabeled provenance. Local receipts remain part of the desktop runner; app builds use the CI gate below.

The CI artifact `askkey-basic-ui-evidence` contains the runner's output and is uploaded even on failure, with seven-day retention. The output location is generated under the ignored UI output directory; it is not a tracked source path. Read logs or bundles only as needed, then delete locally downloaded/generated records. Keep commands, counts, SHAs, and CI links in the PR receipt; do not commit evidence directories. Preserve only evidence explicitly requested by the maintainer or a necessary unresolved-failure reproduction.

The optional `ScreenshotE2ETests` suite runs separately in CI and does not change the required-flow gate. Its window captures use synthetic credentials and simulated authentication, including a cancelled authentication attempt. Download `askkey-basic-ui-evidence` from the PR's **Checks → CI → Artifacts**, or use `gh run download <run-id> -R sudoHG/AskKey -n askkey-basic-ui-evidence -D <temporary-directory>`. Open the PNGs in the artifact's `screenshots/` directory:

```text
01-welcome-first-launch.png
02-welcome-after-first-save.png
03-all-credentials.png
04-template-chooser.png
05-new-credential.png
06-import-preview.png
07-agent-access.png
08-pending-requests.png
09-access-records.png
10-settings.png
11-locked.png
12-approval-default.png
13-approval-details.png
14-approval-cancelled-authentication.png
15-approval-credential-metadata.png
16-approval-organization.png
17-approval-organization-existing-targets.png
18-zh-approval-default.png
19-zh-agent-access.png
```

`18` and `19` are the approval prompt and the Agent access page in Simplified Chinese, used in `README.zh-CN.md`.

An optional capture failure is diagnostic: inspect the screenshot step, its log and xcresult, and the exported subset. A green required-flow job alone does not prove screenshot completeness; #146 acceptance also requires every PNG listed above in the artifact. Delete downloaded evidence after review.

Desktop tests exercise shared App/Broker/helper behavior, but system authentication and external client boundaries use isolated fixtures. Passing them does not validate real Touch ID, production keychain access, a real client task, signing/notarization, or a release. Per [ADR 0006](adr/0006-release-process.md), `Local` and `Release` builds run [release-gate.py](../scripts/release-gate.py): the checkout must be clean, `HEAD` must be reachable from `origin/main` after fetching, and the latest push-to-main `CI` run for that exact commit and both required jobs (`build-and-test`, `basic-ui-flows`) must succeed. Jobs are checked for the run's latest attempt. `Release` also requires the tag `v<product version>` to point at `HEAD`; signing identities, notarization, and explicit maintainer publication approval remain required by the release process.

## Release packaging

[package-release.sh](../scripts/package-release.sh) writes notarized releases as four files: `AskKey-<version>.dmg`, `AskKey-<version>.dmg.sha256`, `AskKey.dmg`, and `AskKey.dmg.sha256`. The stable-named DMG is a byte-identical copy made after all notarization, stapling and Gatekeeper checks pass. Each checksum file names its corresponding DMG. Any existing file or symlink at an output name aborts packaging before any output file is written. The default output directory is `.build/release-artifacts`, not SwiftPM's `.build/release` symlink, which resolves into the build products tree. Pass `--output` to choose another directory.

Notarization needs exactly one of `ASKKEY_NOTARY_PROFILE` (a `notarytool` keychain profile) or `--notary-credential <name>` (an Ask Key credential). `--no-notarize` skips notarization for synthetic packaging checks, writes only `AskKey-<version>-unnotarized.dmg` and its checksum, and cannot be combined with `--notary-credential`. The two notarization modes cannot be combined.

In credential mode each `xcrun notarytool submit … --wait` runs as:

```text
/Applications/Ask Key.app/Contents/Helpers/askkey run --wait-for-approval --credential <name> --operation-id <unique> --caller-name "AskKey release" --caller-purpose "Notarize AskKey <version>" -- xcrun notarytool submit <artifact> --key "$PRIVATE_KEY_FILE" --key-id "$KEY_ID" --issuer "$ISSUER_ID" --wait --output-format json
```

`PRIVATE_KEY_FILE`, `KEY_ID`, and `ISSUER_ID` are the credential's delivery mappings (file path, key id, and issuer id). The script expands them only in the helper's target shell and never prints their values. Tests may point `ASKKEY_RELEASE_HELPER` at a stub; that override is not a release input. Automation tests must not call a real notary service or use the maintainer's identity.

## Pre-release checks on the maintainer's Mac

CI cannot check focus, Touch ID or real clients. Before notarizing, review the release diff for these behaviors, then install the signed `Release` build at `/Applications/Ask Key.app` and walk through this list once with the maintainer. The planner triggers agent requests itself (for example `askkey run --wait-for-approval` with a harmless command that prints no values, or a Codex session); the maintainer only touches the sensor, clicks decisions and reports what they see. Notarize the same build afterwards; its signature hash must match the one tested.

- When a release adds a library migration, have the maintainer back up `~/Library/Application Support/AskKey` to a safe place in Finder before installing; agents never read or copy the production library. Review the release's upgrade notes for migration and downgrade limits. Obtain explicit maintainer approval before installation, quit the old app before replacing it, and launch from Applications with a clean environment rather than a terminal carrying Orca or `CODEX_HOME` variables.
- Check the release version and Broker health. After the upgrade, the library opens without a component-metadata warning, credential counts and names are unchanged, and Agent access settings are kept. Quit and launch again to confirm the same state. If migration fails for a credential, management should remain available and name it after unlock, with editor repair or permanent deletion from the Recycle Bin followed by reopening as the next step; do not alter real credentials to manufacture this failure.
- With Simplified Chinese first in the Mac's preferred languages and the app language set to Follow System, Finder and the Touch ID prompt show 请旨; with English first, both show Ask Key. Finder can retain a stale name in the Launch Services cache until the app is re-registered or the Mac restarts.
- Compare the release machine's `xcrun --sdk macosx --show-sdk-version` and executable marker with the CI marker logs, including the informational window check. If the release SDK differs from the SDK that passed the CI window check (or that job has no passing result), the planner runs the visible management-window check against an isolated dev build marked with the release SDK, with the maintainer present and explicitly approving the local desktop interaction. Check repeated activation for stable size and position before notarization.
- Every Touch ID entry: unlock management, reveal and copy a value, revoke a timed allowance, permanently delete, replace on import, settings actions, approving a read and a write. The prompt accepts a finger without a click.
- With another app's window behind Ask Key, unlock management: Ask Key stays in front afterwards, and its Dock icon does not disappear during the prompt.
- With the management window open behind another app, an agent request arrives: only the approval prompt appears; after Allow and Touch ID, focus returns to the other app.
- Read approval Details shows component names and delivery mappings. Run one harmless CLI `askkey run` and one MCP `run` with an explicit absolute `cwd` through the installed helper; each approval shows the directory used by the command. The commands must not print credential values.
- Cancel one approval's Touch ID authentication, then approve a second request: only the first request is cancelled, the second can authenticate, and a finger is accepted without an extra click.
- While the management import file picker is open, an agent request updates the pending count and posts a reminder without showing an approval prompt. Closing the picker shows the still-pending prompt. The Dock icon stays visible while a management picker or alert is open.
- Click an approval reminder while Ask Key is running: Pending requests opens after unlock. Quit Ask Key, then click a delivered reminder in Notification Center: Ask Key launches and opens Pending requests after unlock. With unsaved changes in the credential editor, clicking a reminder only brings management forward and preserves the draft.
- If an external or scaled display is available, expand a long approval on a short screen and check that the title and action buttons stay visible. Record when this physical-display check is unavailable instead of treating simulated layout tests as device verification.
- Clicking the menu-bar item with the management window open behind another app.
- The sample prompt from Agent access runs as written in a new client session; each supported client that is installed still reports Connected; Claude Code setup still detects its discovery hooks; an SSH request is reminded to look up credentials first.
- After notarization, verify both checksum files in the output directory with `shasum -a 256 -c AskKey-<version>.dmg.sha256` and `shasum -a 256 -c AskKey.dmg.sha256` (replace `<version>` with the release version). Upload all four files (`AskKey-<version>.dmg`, `AskKey-<version>.dmg.sha256`, `AskKey.dmg`, and `AskKey.dmg.sha256`) to the draft release. Obtain the maintainer's explicit approval before pushing the tag or publishing the release, as required by [ADR 0006](adr/0006-release-process.md).

## Receipt and review

Follow [the issue workflow](agents/issue-workflow.md) and [the PR template](../.github/pull_request_template.md). Report the base and head SHAs, changed paths, each acceptance command and outcome, Swift passed/failed/skipped counts when run, comparison with the base, and both CI job results. Explain checks omitted under a documentation-only issue rather than claiming they ran. Before pushing, build locally and run the tests for the changed code with `swift test --filter`, plus the hygiene and module checks; the full suite and desktop flows run in CI, and both CI jobs must be green before acceptance. Address conversation comments, submitted reviews, and inline threads as well as CI failures before presenting the PR for acceptance.
