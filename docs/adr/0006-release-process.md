# ADR 0006: Locally signed, notarized DMG releases

## Status

Accepted for v0.1.0 and later releases until superseded. Narrows the "releases are disabled" decision in [ADR 0005](0005-distribution-and-client-integration.md): releases are allowed only through this process, and each publication needs the maintainer's explicit approval.

## Context

The repository is public, but users can only build AskKey from source. The official topology (`/Applications/Ask Key.app` with `Contents/Helpers/askkey`) and the helper signature checks already assume a Developer ID-signed bundle. `scripts/build-app.sh` has a `Release` mode that signs with the hardened runtime and checks the team, but it does not notarize, package or publish. It also requires a local desktop E2E receipt, which conflicts with the rule that agents do not run desktop UI flows on the maintainer's Mac.

## Decision

- **Where it runs.** Release builds are signed and notarized on the maintainer's Mac. The Developer ID certificate and notarization credentials stay in the maintainer's login keychain; notarization uses a `notarytool` keychain profile named by an environment variable. No signing certificate, notarization key or password is stored in GitHub secrets, CI or the repository.
- **Version.** One Swift constant is the product version. The helper's MCP `serverInfo`, `askkey status`, client verification and the bundle's `CFBundleShortVersionString` all read from it. A release is tagged `v<version>` on a commit reachable from `main`.
- **Gate.** A release or `Local` build requires a clean checkout whose `HEAD` has a successful `CI` workflow run from a push to `main`, with both `build-and-test` and `basic-ui-flows` passing. A `Release` build additionally requires the tag `v<version>` to point at `HEAD`. CI's desktop flows replace the local E2E receipt for this purpose.
- **Artifacts.** A DMG containing `Ask Key.app` and an `Applications` link. The app is notarized and stapled first; the DMG is then signed, notarized and stapled. Gatekeeper must accept both before writing the five output files: `AskKey-<version>.dmg`, `AskKey-<version>.dmg.sha256`, `AskKey.dmg`, `AskKey.dmg.sha256`, and `appcast.xml`. The stable-named DMG is a byte-identical copy of the versioned DMG; each SHA-256 checksum file names its corresponding DMG. `appcast.xml` is the signed update feed for [ADR 0011](0011-in-app-updates.md): `--sparkle-key-credential` names the Ask Key credential that delivers the Sparkle private key, and the feed embeds the `--release-notes` file. Packaging rejects any existing output file or symlink before writing any of the five files. Synthetic `--no-notarize` builds write only `AskKey-<version>-unnotarized.dmg` and its checksum, with the same conflict checks, and no appcast.
- **Publication.** Upload all five files (the four DMG files and `appcast.xml`) and release notes to a draft GitHub Release. The stable names support direct downloads through `releases/latest/download/AskKey.dmg` and `releases/latest/download/AskKey.dmg.sha256`, and `https://askkey.sudohg.com/appcast.xml` redirects to `releases/latest/download/appcast.xml`. The maintainer approves before the draft is published and before the tag is pushed. Publishing the release makes the feed live; no website deploy is needed. ~~There is no updater: users check GitHub Releases for new versions.~~ Superseded by [ADR 0011](0011-in-app-updates.md): the official Release install checks a signed appcast that is published as a Release asset.
  - `releases/latest` is the newest published release that is not a pre-release. A release published without `appcast.xml` makes the feed return 404, and every installed copy silently stops seeing updates until the asset is uploaded. After publishing, read the feed back as described in [docs/testing.md](../testing.md): download it, verify its signature, check its version, and check that its enclosure downloads with the stated length.
  - Security fixes are released with `--critical`. Release notes for a release that migrates the library state its downgrade limit.
  - To pull a bad update, replace the latest release's `appcast.xml` asset with the previous release's (`gh release upload --clobber`). Sparkle never downgrades, so this only stops the offer; then ship a higher, fixed version.
  - Serving the feed directly from the website, or from a mirror for mainland China, is a later change with its own issue. From then on, each release also needs a website deploy.
- **Not included.** ~~Sparkle or any in-app updater,~~ Homebrew, the Mac App Store, and CI-based signing each need their own issue. The updater is decided in [ADR 0011](0011-in-app-updates.md), which supersedes this exclusion. Lokalite's signing team, keys and release entries are never reused.

## Consequences

Every release needs the maintainer present for keychain and notarization prompts, which keeps signing material off shared infrastructure. Release evidence is tied to a CI run for the exact commit instead of a local receipt. v0.1 still has no backup, so release notes and the README must warn users to keep the originals of their credentials elsewhere.
