# ADR 0011: Windows edition

## Status

Proposed. Needs the maintainer's decisions on the open questions below before any implementation issue is written.

## Context

AskKey is a macOS 14+ App. Its security model depends on macOS facilities that have no direct Windows equivalent: a keychain item whose ACL admits only the App binary ([AppKeyStore](../../Sources/AskKeyVault/Keychain/AppKeyStore.swift)), LocalAuthentication for system authentication ([ManagementAuthenticationProcess](../../Sources/AskKeyAppKit/ManagementAuthenticationProcess.swift)), a Unix-domain socket with `SCM_RIGHTS` descriptor passing and POSIX process groups ([AskKeyBrokerC](../../Sources/AskKeyBrokerC/AskKeyBrokerC.c)), code-signature and topology checks on the bundle ([HelperCodeSignatureTrust](../../Sources/AskKeyIntegrations/HelperCodeSignatureTrust.swift), [OfficialInstallTopology](../../Sources/AskKeyBroker/OfficialInstallTopology.swift)) and a SwiftUI/AppKit interface. Swift on Windows cannot reuse these modules and has weak support for the UI and for GRDB, so the Windows edition is a reimplementation, not a port.

The product rules do not change by platform: the decisions of ADRs 0001-0003, 0008 and 0010 bind the Windows edition. This ADR records only how they are realised on Windows and where Windows forces a weaker or different guarantee.

## Decision

### Stack and repository

- Implement the Windows edition in Rust with Tauri 2 for the UI, in a separate repository (proposed name `sudoHG/AskKey-Windows`, MIT). macOS remains in this repository; neither repository builds the other.
- Cargo workspace crates mirror the macOS module boundaries, with the same allowed dependency directions as [docs/architecture.md](../architecture.md): `askkey-system` (restricted process execution), `askkey-broker` (protocol, transport, approval state machine, runtime), `askkey-vault` (storage, crypto, key protection, delivery), `askkey-integrations` (client adapters), `askkey-app` (Tauri), and `askkey-helper` (the `askkey.exe` binary, depending on `askkey-broker` only). A dependency checker enforces the graph in CI, as `check_module_deps.py` does here.
- Third-party crates are limited to an approved list recorded in the repository (initially `windows`, `rusqlite` with bundled SQLite, `aes-gcm`, `hmac`, `hkdf`, `sha2`, `serde`, `serde_json`, `toml_edit`, `tauri`). Additions need an approving issue, as here.

### Protocol and storage compatibility

- Keep Broker protocol version 1 and its message types, field names and [BrokerLimits](../../Sources/AskKeyBroker/BrokerLimits.swift). Only the transport differs (below). Golden request/response vectors generated from this repository's Swift types are committed to the Windows repository and checked in its tests; a mismatch is a bug in the Windows edition.
- Keep the SQLite schema and migration identifiers `askkey-0001-baseline` and `askkey-0002-drop-legacy-tables`, AES-GCM field encryption, HMAC-SHA256 record authentication with the same HKDF derivation, and the NFC/case-folded name index. Libraries are not moved between platforms in this ADR's scope; schema parity keeps that option open for a future issue.
- First-creation and durability rules of ADR 0001 apply, with `FlushFileBuffers` and `MoveFileExW(MOVEFILE_WRITE_THROUGH)` in place of `fsync` and `rename`. Windows cannot fsync a directory; the ADR accepts NTFS metadata journaling as the substitute and the pending-key recovery rule remains the safety net.

### Platform mapping

| macOS | Windows |
| --- | --- |
| `/Applications/Ask Key.app`, `Contents/Helpers/askkey` | `%ProgramFiles%\Ask Key\Ask Key.exe` and `%ProgramFiles%\Ask Key\askkey.exe`, per-machine install so standard users cannot replace the helper |
| `~/Library/Application Support/AskKey` (`0700`/`0600`) | `%LOCALAPPDATA%\AskKey` (non-roaming), with a protected DACL granting only the current user's SID |
| Keychain service `com.sudohg.askkey.vault` (App-only ACL) | Vault key protected under the name `com.sudohg.askkey.vault` (see Key protection) |
| Development namespaces (`dev`, `AskKey Dev`, `.vault.dev`) | `%LOCALAPPDATA%\AskKey\dev`, `%LOCALAPPDATA%\AskKey Dev`, `com.sudohg.askkey.vault.dev` |
| LocalAuthentication (Touch ID or password) | Windows Hello `UserConsentVerifier` (face, fingerprint or PIN) |
| Unix socket, `SCM_RIGHTS` | Named pipe `\\.\pipe\askkey-broker-<user SID>`; handles duplicated by the Broker (below) |
| Process group, `SIGTERM`/`SIGKILL` | Job object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`; `TerminateJobObject` |
| Code signature, resource seal | Authenticode signature and publisher check, install-path check |
| `askkey://` URL scheme | `HKCU\Software\Classes\askkey` registered by the installer |
| Bundle ID `com.sudohg.askkey.app` | Tauri identifier and AppUserModelID `com.sudohg.askkey.app` |
| Signed, notarized DMG | Authenticode-signed MSI (WiX, via Tauri bundler) |

### Key protection

macOS keeps the vault key where only the signed App can read it without a prompt. Windows offers no equivalent for an unpackaged desktop app: DPAPI (`CryptProtectData`, current-user scope) can be unprotected by any process running as the same user.

- Store the vault key wrapped with DPAPI (current-user scope, entropy `com.sudohg.askkey.vault`) in `%LOCALAPPDATA%\AskKey`. The App loads it at startup without UI, matching macOS's non-interactive load, so Allow keeps working while the App runs.
- Record in the Windows `SECURITY.md` that at-rest protection against same-user processes is weaker than on macOS: such a process can decrypt the library. This extends the existing same-user boundary in [SECURITY.md](../../SECURITY.md) and must be stated, not hidden.
- A stronger mode, where the key is wrapped by a Windows Hello (TPM-backed) key and unlocking requires a Hello gesture at App start, is an open question below.

### Broker transport

- Create the pipe with `FILE_FLAG_FIRST_PIPE_INSTANCE` (the App refuses to start if another process already owns the name), `PIPE_REJECT_REMOTE_CLIENTS`, and a DACL granting only the current user. Keep the length-prefixed framing and all limits.
- The helper verifies the server with `GetNamedPipeServerProcessId`: the image path must be the official App path and its Authenticode signature must match the expected publisher, mirroring `HelperCodeSignatureTrust`. Client identity remains display context, as in ADR 0002.
- Standard streams: instead of sending descriptors, the helper sends the numeric values of its stdin, stdout and stderr handles; the Broker opens the client process (from `GetNamedPipeClientProcessId`, opened once at connect so the PID cannot be reused under it) with `PROCESS_DUP_HANDLE` and duplicates them. The helper still never reads target output, as ADR 0003 requires.

### Runtime execution

- Launch targets with `CreateProcessW` in a new job object, `CREATE_NEW_PROCESS_GROUP` and `CREATE_UNICODE_ENVIRONMENT`, with an explicit handle list (`PROC_THREAD_ATTRIBUTE_HANDLE_LIST`) so only the three stream handles are inherited. Cancellation sends `CTRL_BREAK_EVENT` where a console is shared, then terminates the job after the existing grace period; Windows offers no general graceful stop, and the receipt reports it.
- Build the command line with `CommandLineToArgvW`-compatible quoting. Reject `.bat` and `.cmd` targets and any target that would be interpreted by `cmd.exe`, because their argument parsing defeats quoting (CVE-2024-24576 class). A user who needs a batch file must run it through an explicit interpreter they choose.
- Environment variable names are case-insensitive on Windows. Mapping validation, the inherited-environment allowlist and collision checks compare names case-insensitively. The allowlist adds `SystemRoot`, `PATHEXT`, `COMSPEC` and `TEMP`/`TMP` (pointing at the private run directory).
- Temporary files live in `%LOCALAPPDATA%\AskKey\run` with a protected DACL. Deletion can fail while a target holds a file open; the existing visible-failure-and-retry rule covers it.
- File import rejects reparse points (symbolic links and junctions), alternate data streams, device paths (`\\.\`, `\\?\` to devices) and UNC paths, in addition to the ADR 0003 rules.

### Clients

- Support Claude Code, Codex, Cursor and Grok CLI, with configuration under `%USERPROFILE%` at the paths each client uses on Windows. Adapters keep the preserving-write, rollback and verification rules of ADR 0005. Each client's Windows paths, hook shell and quoting are verified per client before its adapter ships; a client whose Windows behaviour cannot be verified is not offered.

### Testing and release

- CI runs on `windows-latest`: `cargo build`, `cargo test`, `cargo clippy -- -D warnings`, `cargo fmt --check`, the dependency checker, a hygiene checker equivalent to `check_hygiene.py`, and desktop flows through `tauri-driver` (WebDriver). The local-desktop rules in [AGENTS.md](../../AGENTS.md) apply unchanged.
- Releases follow ADR 0006 in spirit: signed on the maintainer's machine, each tag and publication explicitly approved. Authenticode signing replaces notarization.

## Open questions for the maintainer

1. **Key protection mode.** DPAPI only (Allow works unattended, weaker at rest), or Windows Hello unlock at App start (stronger at rest, one gesture per App launch), or both as a setting.
2. **Signing.** Which Authenticode source: Azure Trusted Signing, an OV certificate, or an EV certificate. Unsigned builds trigger SmartScreen warnings and break the helper's server verification.
3. **Install scope.** Per-machine (`%ProgramFiles%`, needs administrator rights once, helper not user-writable) as proposed, or per-user (`%LOCALAPPDATA%\Programs`, no elevation, helper replaceable by same-user processes).
4. **Minimum Windows version.** Windows 11 only, or Windows 10 22H2 as well (end of support October 2025).
5. **Repository name and first release target**, for example a v0.1 with Allow/Ask/Hidden, CLI `run`, MCP and Claude Code only.

## Consequences

Windows users get the same permission and approval model, protocol and schema. The edition cannot claim macOS's App-bound key protection while DPAPI-only mode is used, cannot run batch files directly, and cannot stop targets gracefully in every case; each limitation is documented rather than worked around. Two codebases must be kept in step: protocol and schema changes here require a matching Windows issue, and the golden vectors make drift visible.
