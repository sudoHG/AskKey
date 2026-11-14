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

[Tests/UI/required-flows.json](../Tests/UI/required-flows.json) currently lists 17 required flows. They cover explicit connection checks, completion feedback, missing discovery, cancellation and retry, denial, one-time approval and replay, pending cancellation, active-helper disconnection, pending-approval invalidation after restart, credential management persistence, management-window locking, the About panel staying in front of the management window, and a real click on Settings → Devices → **Pair a Device…** opening its sheet. Every required flow must pass with zero failed tests, skips, or expected failures. A subset or zero executed tests is not acceptance.

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

The backup flow (#274) adds eight captures with synthetic credentials, in English (`22`–`25`) and Simplified Chinese (`26`–`29`): the first-run screen with **Restore from Backup…**, the recovery key sheet, an import preview with one renamed conflict, and the import result. They drive the real save and open panels through Go to Folder. `scripts/e2e-report.py` does not export them into `screenshots/` yet, so take them from the attachments of the artifact's `basic-flows.xcresult` with `xcrun xcresulttool export attachments --path <xcresult> --output-path <temporary-directory>`:

```text
22-en-backup-restore-welcome.png
23-en-backup-recovery-key.png
24-en-backup-import-preview.png
25-en-backup-import-result.png
26-zh-backup-restore-welcome.png
27-zh-backup-recovery-key.png
28-zh-backup-import-preview.png
29-zh-backup-import-result.png
```

The Devices section (#288) adds twelve captures in English (`30`–`34`, `40`) and Simplified Chinese (`35`–`39`, `41`). The `screenshots-devices` scenario gives the E2E App fake device services with software keys, an in-memory transport and a simulated iPhone named "Synthetic iPhone" (`Tests/AskKeyTestSupport/E2EDeviceScenario.swift`); every other scenario keeps the build without CloudKit and shows no Devices section. The runner clicks the App's controls, including **Pair a Device…**, which starts the pairing session; fixture commands play the iPhone scanning, revealing, entering its code on the Mac and confirming, answering the delivery check, and the iCloud account signing out. `testPairADeviceOpensItsSheet` checks that the runner's click on **Pair a Device…** opens the pairing sheet. On macOS 26, **Pair a Device…** received no clicks while the Devices box held a single row; the empty list row keeps a second row there ([#299](https://github.com/sudoHG/AskKey/issues/299)). The click test is a required flow (`DevicesE2ETests`, [#301](https://github.com/sudoHG/AskKey/issues/301)) on the same scenario, so a regression fails `basic-ui-flows`; the Devices captures run in the optional screenshot step. The iPhone's code never leaves the App process. Like the backup captures, take them from the attachments of `basic-flows.xcresult`:

```text
30-en-devices-list.png                 the list with one paired iPhone
31-en-devices-pairing-qr-code.png      the pairing sheet with its QR code
32-en-devices-pairing-waiting.png      waiting for the iPhone's reveal
33-en-devices-pairing-code-entry.png   the field for the code the iPhone shows
34-en-devices-icloud-signed-out.png    iCloud signed out, the device unreachable
35-zh-devices-list.png
36-zh-devices-pairing-qr-code.png
37-zh-devices-pairing-waiting.png
38-zh-devices-pairing-code-entry.png
39-zh-devices-icloud-signed-out.png
40-en-devices-empty.png                no paired device yet
41-zh-devices-empty.png
```

An optional capture failure is diagnostic: inspect the screenshot step, its log and xcresult, and the exported subset. A green required-flow job alone does not prove screenshot completeness; #146 acceptance also requires every PNG listed above in the artifact. Delete downloaded evidence after review.

Desktop tests exercise shared App/Broker/helper behavior, but system authentication and external client boundaries use isolated fixtures. Passing them does not validate real Touch ID, production keychain access, a real client task, signing/notarization, or a release. Per [ADR 0006](adr/0006-release-process.md), `Local` and `Release` builds run [release-gate.py](../scripts/release-gate.py): the checkout must be clean, `HEAD` must be reachable from `origin/main` after fetching, and the latest push-to-main `CI` run for that exact commit and both required jobs (`build-and-test`, `basic-ui-flows`) must succeed. Jobs are checked for the run's latest attempt. `Release` also requires the tag `v<product version>` to point at `HEAD`; signing identities, notarization, and explicit maintainer publication approval remain required by the release process.

## Release packaging

[package-release.sh](../scripts/package-release.sh) writes notarized releases as five files: `AskKey-<version>.dmg`, `AskKey-<version>.dmg.sha256`, `AskKey.dmg`, `AskKey.dmg.sha256`, and the signed update feed `appcast.xml`. The stable-named DMG is a byte-identical copy made after all notarization, stapling and Gatekeeper checks pass. Each checksum file names its corresponding DMG. Any existing file or symlink at an output name aborts packaging before any output file is written. The default output directory is `.build/release-artifacts`, not SwiftPM's `.build/release` symlink, which resolves into the build products tree. Pass `--output` to choose another directory.

Notarization needs exactly one of `ASKKEY_NOTARY_PROFILE` (a `notarytool` keychain profile) or `--notary-credential <name>` (an Ask Key credential). `--no-notarize` skips notarization for synthetic packaging checks, writes only `AskKey-<version>-unnotarized.dmg` and its checksum and no appcast, and cannot be combined with `--notary-credential`, `--sparkle-key-credential`, `--release-notes` or `--critical`. The two notarization modes cannot be combined.

In credential mode the runner invokes the helper separately for each submit, history query, or status query. Each target shell runs one notarytool request:

```text
askkey run --wait-for-approval --credential <name> --operation-id <unique> --caller-name "AskKey release" --caller-purpose "Notarize AskKey <version>" -- /bin/bash -c 'set +x; set -eu; [[ -f "$PRIVATE_KEY_FILE" && -r "$PRIVATE_KEY_FILE" ]] || exit 1; printf "%s\n" ASKKEY_NOTARY_REQUEST_STARTED; exec xcrun notarytool "$@" --key "$PRIVATE_KEY_FILE" --key-id "$KEY_ID" --issuer "$ISSUER_ID" --output-format json' bash <action> <arguments>
```

`PRIVATE_KEY_FILE`, `KEY_ID`, and `ISSUER_ID` are the credential's delivery mappings (file path, key id, and issuer id). They expand only in each helper's target shell and are never printed. Each request receives a fresh regular key file managed by Ask Key; the runner does not read, cache, or copy it. The target-shell command stays well below the broker's 4 KiB per-argument limit. Before the first request, packaging asks the operator to approve the first card with a timed allowance (Allow for N Minutes) covering the remaining run. One approval per artifact is not guaranteed: later requests can ask again if an allowance was not granted or has expired, and approval waiting consumes the same deadline. Keychain-profile mode calls notarytool directly. Tests may point `ASKKEY_RELEASE_HELPER` at a stub; that override is not a release input. Automation tests must not call a real notary service or use the maintainer's identity.

The runner submits with `--no-wait`, reports every validated submission ID, and polls `notarytool info` under one 30-minute monotonic deadline per artifact. Processing and transient NSURLErrorDomain errors (-1001, -1003, -1004, -1005, -1006 and -1009) use backoff starting at 5 seconds and capped at 60 seconds. Both helper requests (including approval waiting) and direct profile requests are capped at 5 minutes for submit or 2 minutes for queries, bounded by the remaining budget. Raw tool output stays in memory; permanent errors and rejected submissions stop with sanitized diagnostics.

A transient submit failure without an ID first reconciles `notarytool history` by artifact name and creation time since the first upload attempt, rounded down to the second. Same-name entries in the three minutes before that time are ambiguous: stop and report their IDs instead of ignoring or adopting them. One unambiguous new match is adopted; multiple matches, permanent history failures, or invalid history stop the run. Transient history errors are retried and do not count as empty snapshots. Only three successful empty snapshots allow another upload, with at most three upload attempts total. A known submission is never resubmitted. History visibility and larger clock skew can still affect reconciliation; real notarization and network recovery remain to be verified at the next release.

An adopted submission still In Progress at the deadline gets a distinct diagnostic: its upload may be incomplete, so inspect its notarytool log before resubmitting. Failures retain all observed IDs with credential-free log commands; INT and TERM handlers also print IDs already saved in the response file before cleanup. An upload-started event preserves history guidance even if a later approval or credential-delivery request fails without an ID. Before any upload attempt, approval/delivery failures do not suggest history lookup; a helper killed at the overall deadline reports the deadline rather than approval denial. Resuming stapling from an existing submission ID is outside this flow.

Notarized runs also need `--sparkle-key-credential <name>`, the Ask Key credential that delivers the Sparkle private key file as `SPARKLE_ED_KEY_FILE`, and `--release-notes <file>`; `--critical` marks the update critical and is used for security fixes. The options, the release-notes format, and an app `CFBundleVersion` equal to the product version are checked before any notarization request. After the DMG passes Gatekeeper and the output names are free, packaging asks for one approval:

```text
askkey run --wait-for-approval --credential <name> --operation-id <unique> --caller-name "AskKey release" --caller-purpose "Sign the AskKey <version> update feed" -- /bin/bash -c 'set +x; set -eu; exec python3 "$@" --ed-key-file "$SPARKLE_ED_KEY_FILE"' bash scripts/generate-appcast.py <staged DMG> --version <version> --release-notes <file> --output <staging>/appcast.xml [--critical]
```

[generate-appcast.py](../scripts/generate-appcast.py) signs the stapled DMG and then the feed with `sign_update` from `.build/artifacts/sparkle/Sparkle/bin`, the SwiftPM artifact pinned by `Package.resolved` (present after `swift build` or `swift package resolve`), and verifies both before writing the feed. `sign_update --verify` derives the public key from the delivered private key, so the generator also checks the DMG signature against `scripts/sparkle-public-key.txt` with CryptoKit (`/usr/bin/xcrun swift`, which receives only the public key, the signature and the DMG path); a delivered key that does not match the key built into the app fails packaging before anything is written. Its `--public-key-file` option exists for tests, and packaging never passes it. The key path expands only in the target shell, `sign_update` output is never shown because it can echo key material, and no keychain item is read or created. [ADR 0011](adr/0011-in-app-updates.md) (Publication) describes the feed's item. Automation tests use only synthetic Ed25519 seed files in temporary directories and the fixture `askkey`.

The release-notes file is UTF-8 Markdown with two sections, each starting with its marker line: `<!-- lang: en -->` for English, then `<!-- lang: zh-Hans -->` for Simplified Chinese, with nothing but blank lines before the first marker. Both are embedded in the signed feed, and the update window shows the one that matches Ask Key's language setting (for Follow System, the Mac's preferred languages), so describe what changed for the user and leave download and install steps to the GitHub Release. Release notes for a release that migrates the library state its downgrade limit in both sections.

### CloudKit signing for Local builds

Device pairing (ADR 0013 in [#291](https://github.com/sudoHG/AskKey/pull/291)) needs CloudKit and push. A `Local` build gets them when `ASKKEY_PROVISIONING_PROFILE` names a Developer ID provisioning profile for `com.sudohg.askkey.app`; `ASKKEY_CODESIGN_IDENTITY` and `ASKKEY_APPLE_TEAM_ID` are required as for every `Local` build:

```bash
ASKKEY_PROVISIONING_PROFILE=<path to the .provisionprofile> bash scripts/build-app.sh Local
```

A relative path is resolved against the directory the script is started from. The variable turns the option on whenever it is set, even to an empty value, so leave it unset for every other build. The build always uses the Production CloudKit environment, so a new container or environment must first be set up as in [CloudKit setup for a new container or environment](#cloudkit-setup-for-a-new-container-or-environment).

Before building, [cloudkit-signing.py](../scripts/cloudkit-signing.py) copies the profile to `.build/cloudkit-signing/`, decodes the copy with `security cms -D` and refuses it unless it is a macOS Developer ID profile (all devices, no device list) whose App ID is `com.sudohg.askkey.app` in the team from `ASKKEY_APPLE_TEAM_ID`, has not expired, lists the certificate that `ASKKEY_CODESIGN_IDENTITY` resolves to (exactly one valid signing identity in the keychain, matched the way `codesign` matches names and hashes), and grants the CloudKit service, the container `iCloud.com.sudohg.askkey`, the Production CloudKit environment and production push. These checks read the profile's content; they do not check that Apple signed it, which macOS does when the App launches. Before any signing, the build adds `CloudKitContainerIdentifier` with the container to Info.plist and embeds the checked copy as `Contents/embedded.provisionprofile`. It then generates `.build/cloudkit-signing/AskKeyApp.entitlements` with exactly `com.apple.application-identifier`, `com.apple.developer.team-identifier`, `com.apple.developer.icloud-services = [CloudKit]`, `com.apple.developer.icloud-container-identifiers = [iCloud.com.sudohg.askkey]`, `com.apple.developer.icloud-container-environment = Production` and `com.apple.developer.aps-environment = production`, and signs with the checked certificate's hash. Nested code is signed inside out as before, without entitlements; only the App carries them. After signing, the build reads back the signed entitlements, the leaf certificate and the embedded profile, fails if any of them differs from what was checked or if the signature does not seal the profile, and then runs the strict signature verification.

`Release` refuses the option until [#269](https://github.com/sudoHG/AskKey/issues/269) stage 4 ships the iPhone app, and `Debug` and `E2E` refuse it because ad hoc signing cannot carry these entitlements. Without the option every mode builds as before, and [AskKeyApp.entitlements](../AskKeyApp.entitlements) stays empty. No Team ID, signing identity, certificate or profile is committed; the team comes from the environment at build time, and messages never print it. Automation tests run `build-app.sh` against synthetic build products, signing tools and decoded profiles; signing a real build needs the maintainer's identity and profile.

When the App carries `Contents/embedded.provisionprofile`, `package-release.sh` checks the staged copy before notarizing, also with `--no-notarize`: `ASKKEY_APPLE_TEAM_ID` is then required, the profile must still pass the checks above for the App's leaf certificate and be the one the signature sealed, the Info.plist must declare the container, and the signed entitlements must be exactly the set above. The DMG keeps the profile.

## iPhone app

The pairing-only iPhone app (#289, ADR 0013 → iPhone app) lives in `iOS/`. [build-ios.sh](../scripts/build-ios.sh) generates `iOS/AskKeyiOS.xcodeproj` from `iOS/project.yml` with XcodeGen (the project is never committed), checks that both String Catalogs have English and Simplified Chinese with matching placeholders and that every key the kit uses exists, and keeps its build output in `.build/ios`. It needs XcodeGen, an iOS Simulator runtime and at least 80 GiB free:

```bash
bash scripts/build-ios.sh build
bash scripts/build-ios.sh test
```

| Mode | Coverage and limits |
| --- | --- |
| `build` | Builds the app target `AskKeyiOS` for the iOS Simulator, unsigned. The build has no CloudKit container in its Info.plist, so it never creates one. |
| `test` | Runs `AskKeyiOSKitTests` on the newest available iPhone simulator, without an app host, and writes the rendered screens to `.build/ios/screens` (each screen state in English and Simplified Chinese). The tests drive the real `DeviceMessenger` with software keys, an in-memory keychain and an in-memory account; the Mac side is a second messenger. They do not run the Secure Enclave, Face ID, the keychain, CloudKit or push. |
| `export` | The maintainer's Ad Hoc build for #290: `ASKKEY_APPLE_TEAM_ID=<team> bash scripts/build-ios.sh export` archives with automatic signing for that team (`-allowProvisioningUpdates`), puts `CloudKitContainerIdentifier` in the Info.plist, exports with the Production CloudKit environment, and reads back the signed entitlements (application identifier, team, `aps-environment = production`, the container and CloudKit service, the keychain access group) and the Info.plist. Before the first export for a new App ID or container, see [CloudKit setup for a new container or environment](#cloudkit-setup-for-a-new-container-or-environment). Agents do not run it. |

The CI job `ios-app` runs `build` and `test` on `macos-latest` and uploads the screens as the `askkey-ios-screens` artifact; `release-gate.py` does not require it, but a PR that changes the app needs it green and the maintainer reviews the English and Chinese screens before merge. Do not launch the app in a simulator on the maintainer's Mac. Signing, the Secure Enclave, Face ID, the keychain access group, CloudKit and push are verified on a real iPhone in #290.

### CloudKit setup for a new container or environment

Production accepts the device subscriptions only after they exist in the Development environment and the schema has been deployed from there. Importing the schema creates no subscription. In [#290](https://github.com/sudoHG/AskKey/issues/290) every Production `SubscriptionCreate` therefore failed with `BAD_REQUEST` on both devices while zone saves succeeded, and the iPhone's welcome step stopped at "iCloud didn't finish setting up Ask Key's inbox. Try again in a moment."

Steps 2 and 4 use the iPhone export. Xcode's automatic signing, which `build-ios.sh export` uses, registered `com.sudohg.askkey.ios` with iCloud but without the container, and the export failed until the App ID had it. Before the first export for a new App ID or container, assign `iCloud.com.sudohg.askkey` in the App ID's iCloud capability in the developer portal, then delete Xcode's stale cached team provisioning profile for the App ID from `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` (`security cms -D -i <file>` shows which App ID a profile is for), so the next export fetches a profile with the container. The export's read-back then lists the container.

Set up a new container or environment in this order, and check each step before the next:

1. Import `CloudKit/schema.ckdb` into Development. `cktool` needs a management token from CloudKit Console, saved once with `xcrun cktool save-token --type management`:

   ```bash
   xcrun cktool import-schema --team-id <team> --container-id iCloud.com.sudohg.askkey --environment development --file CloudKit/schema.ckdb
   ```

   Check: `xcrun cktool export-schema` with the same team, container and environment lists `AlertMessage` and `QuietMessage` with the fields in the file.
2. Create both subscriptions in Development by running a development-signed iPhone build once. `build-ios.sh export` leaves one in its archive. Install it, then open it on the iPhone until it shows its list of paired Macs:

   ```bash
   xcrun devicectl device install app --device <iPhone name or UDID> .build/ios/AskKeyiOS.xcarchive/Products/Applications/AskKey.app
   ```

   The Mac has no development-signed CloudKit build, and it needs none: after the iPhone's run, Production accepted the Mac's subscriptions too. Check: CloudKit Console → Logs for Development shows two successful `SubscriptionCreate` requests, and the iPhone's unified log (subsystem `com.sudohg.askkey.ios`, category `CloudKitInbox`) has one `Saved subscription …` line ending in `_alert` and one in `_quiet`. Do not pair while this build is installed: it uses Development, and the Mac's build uses Production.
3. Deploy the schema to Production in CloudKit Console. Deploy even when the Console shows 0 changes: creating the subscriptions changed the Development schema without a visible difference. If the Console reports "Schema uuid stale", reload it and deploy again. Check: the Console confirms the deployment; whether Production now accepts the subscriptions shows only in the next step.
4. Install the Ad Hoc export on the iPhone again, and open it and the Mac's `Local` build with the CloudKit option. Check: Console → Logs for Production shows successful `SubscriptionCreate` requests from both devices, and each device logs `Saved subscription …` for `_alert` and `_quiet` (the Mac in subsystem `com.sudohg.askkey.app`). On later launches a device only fetches its subscriptions and saves none.

The subscription IDs in these lines contain the device ID; report them as `_alert` and `_quiet`. To browse the private database in CloudKit Console, choose **Act As iCloud Account…** at the bottom of the left sidebar and sign in with the Apple Account the devices use.

To read the iPhone's unified log, connect it by cable, unlock it, and collect by its UDID. `--device` takes the first paired device, which may be an Apple TV or a Watch:

```bash
sudo log collect --device-udid <UDID> --last 30m --output <directory>/iphone.logarchive
```

`xcrun devicectl list devices --columns hardwareProperties.udid` prints the UDID in its last column; the Identifier column is a different ID. Open the archive in Console or with `log show --archive`, and delete it after reading: it holds the iPhone's whole log.

## Pre-release checks on the maintainer's Mac

CI cannot check focus, Touch ID or real clients. Before notarizing, review the release diff for these behaviors, then install the signed `Release` build at `/Applications/Ask Key.app` and walk through this list once with the maintainer. The planner triggers agent requests itself (for example `askkey run --wait-for-approval` with a harmless command that prints no values, or a Codex session), one request at a time with explicit instructions; delay requests that coincide with screen lock so the maintainer never waits at the lock screen. The maintainer only touches the sensor, clicks decisions and reports what they see. Notarize the same build afterwards; its signature hash must match the one tested. Device checks remain `NOT_VERIFIED` until performed; passing synthetic tests or CI is not device verification.

- When a release adds a library migration, have the maintainer back up `~/Library/Application Support/AskKey` to a safe place in Finder before installing; agents never read or copy the production library. Review the release's upgrade notes for migration and downgrade limits. Obtain explicit maintainer approval before installation, quit the old app before replacing it, and launch from Applications with a clean environment rather than a terminal carrying Orca or `CODEX_HOME` variables.
- Check the release version and Broker health. For 0.5.0 → 0.6.0, no library migration or library backup is required: the library opens without a component-metadata warning, credential counts and names are unchanged, Agent access is not paused, and no Resume banner appears. Read authentication, timed-allowance settings and End Timed Allow on Lock are kept. Quit and launch again to confirm the same state. For a release that does migrate, if migration fails for a credential, management should remain available and name it after unlock, with editor repair or permanent deletion from the Recycle Bin followed by reopening as the next step; do not alter real credentials to manufacture this failure.
- With Simplified Chinese first in the Mac's preferred languages and the app language set to Follow System, Finder and the Touch ID prompt show 请旨; with English first, both show Ask Key. Finder can retain a stale name in the Launch Services cache until the app is re-registered or the Mac restarts. Check the group read card and Settings in both languages, including the localized End Timed Allow on Lock and Revoke Group Allowance labels.
- With Simplified Chinese first in the Mac's preferred languages, set Ask Key's language to English: Ask Key's own windows switch at once, and the note under Language says the menu bar and system windows switch after Ask Key reopens. Default Timed Allow and Global Shortcut show English titles. Quit and open Ask Key again: with the management window in front, the menu bar (Ask Key, Edit, View, Window, Help), About Ask Key and the Import panel are in English, and so is Sparkle's question about checking automatically if it appears on this launch. Set Follow System and reopen: they are in Chinese again. Repeat with English first on the Mac and Simplified Chinese in Ask Key.
- In English and Simplified Chinese, Settings → General shows **Check for Updates Automatically** and **Check for Updates…**, and the menu bar icon's menu and its right-click menu show **Check for Updates…** above Quit. The question about checking automatically appears on the second launch of the installed release, not the first. Leave **Check for Updates…** unclicked until the release is published: before that, the feed still serves the previous release's appcast, or returns 404 when that release has none.
- Compare the release machine's `xcrun --sdk macosx --show-sdk-version` and executable marker with the CI marker logs, including the informational window check. If the release SDK differs from the SDK that passed the CI window check (or that job has no passing result), the planner runs the visible management-window check against an isolated dev build marked with the release SDK, with the maintainer present and explicitly approving the local desktop interaction. Check repeated activation for stable size and position before notarization.
- Read back the signing of the build under test. Until [#269](https://github.com/sudoHG/AskKey/issues/269) stage 4, a `Release` build carries no CloudKit signing: `codesign -d --entitlements - --xml "/Applications/Ask Key.app"` prints no entitlements, there is no `Contents/embedded.provisionprofile`, and Info.plist has no `CloudKitContainerIdentifier`. For a build with the CloudKit option (a `Local` build now, `Release` from stage 4), the signed entitlements are exactly the six listed in [CloudKit signing for Local builds](#cloudkit-signing-for-local-builds), and `security cms -D -i "<app>/Contents/embedded.provisionprofile"` shows a Developer ID profile (`ProvisionsAllDevices`) for `com.sudohg.askkey.app` that grants the container, the `Production` CloudKit environment and `production` push. Both outputs contain the Team ID: read them in the terminal and never paste them into an issue, a pull request or release notes. A build against a container or environment that has not been set up as in [CloudKit setup for a new container or environment](#cloudkit-setup-for-a-new-container-or-environment) cannot create its subscriptions.
- In the same profile output, check `ExpirationDate`. macOS checks the embedded profile when the App launches, so renew the profile and rebuild well before that date.
- Before testing notifications, unregister stale copies of `com.sudohg.askkey.app` from Launch Services; `Local` builds share the bundle ID. In [#281](https://github.com/sudoHG/AskKey/issues/281), registrations for a deleted build directory and a copy under `/tmp` made macOS refuse notification authorization. List the registered paths, unregister every one except the build under test, and run that build from a normal folder, not `/tmp`:

  ```bash
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREGISTER" -dump | awk '/^path:/ { sub(/^path: +/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 } /^identifier: +com\.sudohg\.askkey\.app$/ { print path }'
  "$LSREGISTER" -u "<stale path>"
  ```

- Every Touch ID entry: unlock management, reveal and copy a value, revoke a single or group timed allowance, permanently delete, replace on import, settings actions, approving a single or group read and a write. The prompt accepts a finger without a click. Turning End Timed Allow on Lock on asks for authentication; cancellation leaves it off. After enabling it, relaunch and confirm it stays on; turning it off also asks for authentication.
- With the management window in front, choose **About Ask Key** from the app menu: the panel opens in front, the Dock icon and the menu bar stay, and closing the panel returns to the management window.
- With another app's window behind Ask Key, unlock management: Ask Key stays in front afterwards, and its Dock icon does not disappear during the prompt.
- With the management window open behind another app, an agent request arrives: only the approval prompt appears; after Allow and Touch ID, focus returns to the other app.
- Read approval Details shows component names and delivery mappings. For a grouped credential, in English and Simplified Chinese, Details lists every eligible credential, excludes Hidden, expired and recycled credentials, and shows Expires when a member expires before the selected duration. Later additions are excluded from the grant. Approving the group creates one library row with all covered credentials, remaining time and Revoke Group Allowance; it remains visible through search and group filters. A member's inspector shows Revoke Group Allowance, and revoking it ends the whole grant. Run one harmless CLI `askkey run` and one MCP `run` with an explicit absolute `cwd` through the installed helper; each approval shows the directory used by the command. The commands must not print credential values.
- Cancel one approval's Touch ID authentication, then approve a second request: only the first request is cancelled, the second can authenticate, and a finger is accepted without an extra click.
- While the management import file picker is open, an agent request updates the pending count and posts a reminder without showing an approval prompt. Closing the picker shows the still-pending prompt. The Dock icon stays visible while a management picker or alert is open.
- Click an approval reminder while Ask Key is running and management is locked: the pending approval card opens directly, management stays locked, and its remembered page and sidebar selection survive unlocking. With nothing pending, the click only brings the window forward. With management already unlocked, a pending reminder opens Pending requests. With unsaved changes in the credential editor, clicking a reminder only brings management forward and preserves the draft. An agent write-failure notification brings Ask Key forward without jumping to Pending requests. Separately, quit Ask Key and click a delivered reminder in Notification Center to check launch and the queue-dependent behavior above while management stays locked; this cold-launch check remains `NOT_VERIFIED` from v0.4.0 until performed.
- With End Timed Allow on Lock enabled, create one single and one group allowance, lock with ⌃⌘Q for at least five seconds, and unlock: the list is empty and the next read asks again. A request sent just before locking stays pending and posts its reminder. Through five quick lock/unlock cycles, the interface remains responsive. Turn the setting off and confirm allowances survive a lock without a Keychain prompt.
- With the setting enabled, choose Apple menu > Sleep, wake and unlock: allowances are gone, and a new timed approval works immediately after wake. If the maintainer elects to test fast user switch, confirm allowances end on switching away and fresh timed approval works after returning. Passwordless wake is also optional; record either optional check as `NOT_VERIFIED` when omitted.
- If an external or scaled display is available, expand a long group approval on a short screen in English and Simplified Chinese and check that the title and all action buttons stay visible while Details scrolls. Check centred empty states for an empty library, an empty group and a search with no results, with and without an active allowance row above them. Record when the physical-display check is unavailable instead of treating simulated layout tests as device verification.
- Clicking the menu-bar item with the management window open behind another app.
- The sample prompt from Agent access runs as written in a new client session; each supported client that is installed still reports Connected; Claude Code setup still detects its discovery hooks; an SSH request is reminded to look up credentials first.
- After notarization, verify both checksum files in the output directory with `shasum -a 256 -c AskKey-<version>.dmg.sha256` and `shasum -a 256 -c AskKey.dmg.sha256` (replace `<version>` with the release version). Upload all five files (`AskKey-<version>.dmg`, `AskKey-<version>.dmg.sha256`, `AskKey.dmg`, `AskKey.dmg.sha256`, and `appcast.xml`) to the draft release. Obtain the maintainer's explicit approval before pushing the tag or publishing the release, as required by [ADR 0006](adr/0006-release-process.md). Publishing the release makes the feed live through the website's redirect to `releases/latest/download/appcast.xml`; no website deploy is needed.
- Right after publishing, read the feed back. `releases/latest` is the newest published release that is not a pre-release, so a release published without `appcast.xml` makes the feed return 404, and every installed copy silently stops seeing updates until the asset is uploaded. `sign_update --verify` derives the public key from the private key file, so the signature check runs through the Sparkle key credential. Paste the commands into an interactive terminal; each check prints `OK:` or `FAILED:`, and any `FAILED:` line means the feed is not usable:

  ```bash
  VERSION="$(bash scripts/product-version.sh)"
  FEED_DIR="$(mktemp -d)"
  curl -fsSL -o "$FEED_DIR/appcast.xml" https://askkey.sudohg.com/appcast.xml && echo "OK: downloaded the feed" || echo "FAILED: cannot download the feed"
  "/Applications/Ask Key.app/Contents/Helpers/askkey" run --wait-for-approval --credential <name> --operation-id "$(uuidgen)" --caller-name "AskKey release" --caller-purpose "Verify the AskKey $VERSION update feed" -- /bin/bash -c 'set +x; set -eu; "$1" --verify --ed-key-file "$SPARKLE_ED_KEY_FILE" "$2" >/dev/null 2>&1' bash "$PWD/.build/artifacts/sparkle/Sparkle/bin/sign_update" "$FEED_DIR/appcast.xml" && echo "OK: feed signature verified" || echo "FAILED: feed signature did not verify"
  grep -Fq "<sparkle:version>$VERSION</sparkle:version>" "$FEED_DIR/appcast.xml" && echo "OK: feed version $VERSION" || echo "FAILED: feed version is not $VERSION"
  URL="$(sed -n 's/.*<enclosure url="\([^"]*\)".*/\1/p' "$FEED_DIR/appcast.xml")"
  LENGTH="$(sed -n 's/.*<enclosure [^>]*length="\([0-9]*\)".*/\1/p' "$FEED_DIR/appcast.xml")"
  curl -fsSL -o "$FEED_DIR/enclosure.dmg" "$URL" && echo "OK: downloaded the enclosure" || echo "FAILED: cannot download the enclosure"
  [ -n "$LENGTH" ] && [ "$(stat -f %z "$FEED_DIR/enclosure.dmg" 2>/dev/null)" = "$LENGTH" ] && echo "OK: enclosure length $LENGTH" || echo "FAILED: enclosure length does not match the feed"
  rm -rf "$FEED_DIR"
  ```

- After the read-back, choose **Check for Updates…** on the installed release: it reports that the version is up to date. Choose it once from Settings with the management window in front and once from the menu bar icon's menu with management closed; each time Sparkle's window opens in front of other apps. A real update and the relaunch gate can only be checked from an updater-enabled previous version, so for 0.6.0, the first release with the updater, both stay `NOT_VERIFIED` until the next release.
- For the first release after an updater-enabled one, install the previous version at `/Applications/Ask Key.app`, update with **Check for Updates…**, and confirm that the library, keychain access, client configurations and running agents keep working. The feed goes live only when the release is published, so run this check right after the read-back; if it fails, pull the update.
- To pull a bad update, with the maintainer's approval, replace the latest release's `appcast.xml` asset with the previous release's: download it with `gh release download v<previous> --repo sudoHG/AskKey --pattern appcast.xml --dir <temporary directory>`, upload it with `gh release upload v<version> <temporary directory>/appcast.xml --repo sudoHG/AskKey --clobber`, and read the feed back. Sparkle never downgrades, so this only stops the offer to copies that have not installed the update; then ship a higher, fixed version. Serving the feed directly from the website, or from a mirror for mainland China, is a later change with its own issue; from then on, each release also needs a website deploy.

## Receipt and review

Follow [the issue workflow](agents/issue-workflow.md) and [the PR template](../.github/pull_request_template.md). Report the base and head SHAs, changed paths, each acceptance command and outcome, Swift passed/failed/skipped counts when run, comparison with the base, and both CI job results. Explain checks omitted under a documentation-only issue rather than claiming they ran. Before pushing, build locally and run the tests for the changed code with `swift test --filter`, plus the hygiene and module checks; the full suite and desktop flows run in CI, and both CI jobs must be green before acceptance. Address conversation comments, submitted reviews, and inline threads as well as CI failures before presenting the PR for acceptance.
