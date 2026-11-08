# ADR 0012: Encrypted backup export and merge import

## Status

Accepted. Implementation is tracked in [#270](https://github.com/sudoHG/AskKey/issues/270): [#272](https://github.com/sudoHG/AskKey/issues/272) adds export and inspection, [#273](https://github.com/sudoHG/AskKey/issues/273) adds the merge import, and [#274](https://github.com/sudoHG/AskKey/issues/274) adds the Settings and first-run interface and the documentation. Amends [ADR 0004](0004-backup-removal-and-future-design.md); see [Amendments to ADR 0004](#amendments-to-adr-0004).

## Context

A person who keeps credentials in Ask Key has no way to move them off one Mac and onto another. A lost, replaced or erased Mac means re-entering every credential from its original, and a person who runs agents on several Macs has to type each credential in again on each of them. [#242](https://github.com/sudoHG/AskKey/issues/242) asked for backup and restore; it is stage 0 of the multi-device roadmap in [#269](https://github.com/sudoHG/AskKey/issues/269).

[ADR 0004](0004-backup-removal-and-future-design.md) removed the earlier iCloud backup ([#18](https://github.com/sudoHG/AskKey/issues/18)) and set requirements for a future one, including restore by a recoverable atomic replacement of the whole library. Replacement discards everything created after the backup and cannot combine two Macs' libraries, so this design adds instead of replacing. Two lessons from the removed backup carry over: Recycle Bin credentials and empty groups must round-trip, and tests must exercise the real storage path rather than in-memory stand-ins.

## Decision

### Backup file

- One file with the extension `.askkeybackup`. A plaintext header holds a magic string, the format version and a random 32-byte salt, and is authenticated as additional data. The rest of the file is a single AES-256-GCM sealed payload.
- The payload key is HKDF-SHA256 over the recovery secret, with the header salt and a domain-separation label. There is no password stretching, because the secret is high-entropy and machine-generated. CryptoKit only; no new dependency.
- The payload is a versioned snapshot document, independent of the SQLite schema. It carries values in the clear inside the sealed payload and none of the library's ciphertext, record tags or App key, so a backup opens in a library with a different App key. It holds:
  - the backup's creation time and the app version;
  - every group name, including empty groups;
  - every credential, active or in the Recycle Bin and including Hidden ones: display name, payload kind, components (name, text value or file bytes with original filename, delivery mapping, masked flag), usage instructions, private notes, group, permission, expiry, and created, updated and deleted times.
- Not in the snapshot: access records, agent write receipts, pending approvals, timed allowances, the agent access policy (pause, read authentication, timed-allowance settings, End Timed Allow on Lock), App preferences and client configurations.
- The file name and the unencrypted bytes reveal no credential names. The file is processed in memory; the plaintext snapshot is never written to disk.
- Version policy: a reader accepts every format version up to its own and refuses newer ones with an "update Ask Key" error. A writer always writes the current version. Any change in snapshot meaning bumps the version.

### Recovery key

- A 128-bit random secret plus a short checksum, written in Crockford Base32 and shown in groups of four characters. Input ignores case, spaces and hyphens and maps look-alike characters.
- A checksum failure is reported as a typo before any decryption. A decryption failure is reported as "this recovery key does not open this file, or the file is damaged"; the two cases are indistinguishable by design.
- Every export generates a new recovery key. Ask Key never stores it: not in the keychain, the library, logs or preferences. A lost recovery key cannot be recovered, and the file it belongs to cannot be opened.

### Export

- Export is a Vault operation that requires an active management session and fresh system authentication, the same boundary as revealing a stored value. It reads every credential, including Hidden and recycled ones, through the normal record authentication. If any record fails authentication, the export fails rather than producing a partial backup.
- App flow: authenticate → show the recovery key once, with a one-step Copy action → the person re-enters its last group → save panel (default name `Ask Key Backup <date>.askkeybackup`) → the App writes the file atomically with `0600` permissions. The payload is sealed before any byte leaves the App, and the recovery key is confirmed before the file is written. A failed write leaves no partial file.

### Import

An import has three Vault operations: inspect, plan and commit.

- **Inspect** decrypts the file, decodes it strictly and validates every credential with the same validators as normal creation (names, components, delivery mappings, the 64-component and 5 MiB limits, group names), then returns a summary (backup date and counts). Any invalid credential fails the whole file. A wrong recovery key, a checksum typo, a tampered or truncated file, a newer format version, an unknown payload kind, duplicate names inside the backup and an over-limit credential are each refused without any change to the library.
- **Inspect and plan** require a management session or, while the library has no active or recycled credential, the same allowance as first-run creation. A new plan after a library change follows the same rule.
- **Plan** is computed against the current library and presented as the preview: the backup date; the counts to add, skip and rename; every final name of a renamed credential; credentials skipped because their identical copy is in the Recycle Bin; and skipped recycled credentials. The plan is frozen together with a digest of the library state it was computed against.
- **Commit** applies the frozen plan. It requires fresh system authentication and verifies that the library has not changed since planning; if it has, the person is asked to review a new plan.

#### Merge rules

Names match by the existing normalization (NFC and Unicode case folding, see [CredentialName](../../Sources/AskKeyVault/Models/CredentialName.swift)) against every existing credential, including Hidden and recycled ones.

- **No match:** add.
- **Match with identical content:** skip. Identical means the same component names, values, original filenames, delivery mappings, usage instructions and private notes. Group, expiry, permission and timestamps are not compared.
- **Match with different content:** try the candidates `<name> (from backup)`, `<name> (from backup 2)`, `<name> (from backup 3)` and so on, with the suffix in the App's current language (the App supplies the suffix; the Vault adds no user-facing strings). If a candidate already holds identical content, skip; otherwise use the first free candidate. Candidates are checked against the library and against names already assigned in this import, and the base name is shortened so every candidate stays within the name limits. The preview shows every final name. Importing the same backup again therefore adds nothing.
- **Identical copy in the Recycle Bin:** an active backup credential whose identical match is in this library's Recycle Bin is skipped and listed as "in the Recycle Bin; restore it there".
- **Recycled backup credentials:** one whose name matches anything (any existing credential, or a name already assigned in this import) is skipped, and so is one whose 30-day Recycle Bin retention has already ended. A recycled credential that is added stays in the Recycle Bin.

#### What an import writes

- Imported credentials get new IDs. Their created, expiry and deleted times are kept; their updated time is the import time.
- Permissions: Allow becomes Ask every time; Ask every time and Hidden are kept.
- Groups match by normalized name; a matching group keeps its existing spelling. Missing groups, including empty ones, are created. No existing credential changes group.
- Commit is one database transaction under the existing exclusive-change gate. Stored groups are read, merged and written inside that transaction like every other stored-group writer ([ADR 0010](0010-agent-credential-metadata-writes.md)), so either every planned credential and group is written or nothing is. No database file is moved and no crash journal is needed. No existing credential row changes; the stored group list only gains names.
- The import is a management change like creating credentials in the App. A pending approval whose frozen state it changes fails its existing commit-time revalidation, for example an agent organization request naming a group that gains members, or a pending agent create of a name the import takes. Every other approval, timed allowance and delivery stays valid. The catalog-change notification fires once, so imported credentials that are neither Hidden nor in the Recycle Bin appear in the agent catalog right after the import.

### App

- Settings gains a Backup section with **Export Backup…** and **Import Backup…**. Import flow: open panel → recovery key entry → preview → confirm → system authentication → result summary listing what was added and what was renamed.
- The first-run and empty-library screen gains **Restore from Backup…**, which opens the same import flow without creating a credential first. Commit still requires fresh system authentication.
- Every string is in `Localizable.xcstrings`, in English and Simplified Chinese.
- Export and import are authenticated App operations. The Broker gains no operation, and no agent can export, inspect or import a backup.

### Out of scope

Automatic or scheduled backup and uploading to iCloud or any other service (later stages of #269); whole-library replacement or rollback, and undoing an import; selective import of individual credentials, editing during the preview and resolving conflicts in place (renamed pairs are reviewed afterwards with the existing editor); exporting access records, the agent access policy, App preferences or client configurations; user-chosen passwords instead of the generated recovery key, and stored or reused recovery keys; registering the file type so that double-clicking opens Ask Key; streaming very large libraries; readers on other platforms.

## Amendments to ADR 0004

- **Import adds and never replaces**, so ADR 0004's replacement requirement does not apply: there is no recoverable atomic replacement of the library and no recovery to complete before agent service opens. An import runs while agent service runs, under the same exclusive-change gate as other management changes.
- **Approvals are not invalidated wholesale.** A pending approval whose frozen state the import changes fails its normal commit-time revalidation; every other approval and timed allowance stays valid.
- **No import widens a permission:** Allow becomes Ask every time and Hidden stays Hidden. This replaces "credentials must return to Ask", which would have moved Hidden credentials into the agent catalog.
- **The read-authentication setting is left as the person set it,** because no existing credential changes. This replaces "read authentication must be enabled".
- **Rolling the whole library back** to a backup means a local erase followed by an import.
- **Constraints that still apply:** authenticated encryption before the file leaves the App; independent high-entropy recovery material; no credential names in filenames or unencrypted bytes; verification of the complete snapshot before any write; and system authentication before an import writes anything.
- ADR 0004's requirements for providers, partial publication, propagation order, authenticated generations and conflicting writers concern uploading and synchronization. Stage 0 uploads nothing, so they are neither met nor retired here; they still bind the later stages of #269.

## Consequences

One file and its recovery key move a whole credential library to another Mac, restore it into an empty library, or combine two Macs' libraries by importing each one's backup into the other. Existing credentials, permissions, approvals and timed allowances survive an import; conflicting credentials arrive as renamed pairs for the person to resolve with the existing editor.

A backup file holds every credential's value, including Hidden and recycled ones, under one key. Anyone with both the file and its recovery key can read all of it, and nobody can open the file without the key, including Ask Key. A backup whose format version is newer than this reader supports cannot be imported until the app is updated. Because the snapshot is independent of the database schema, later versions keep reading today's backups; the snapshot is the starting point for per-credential records in the sync stage of #269.

The export path, the inspect step and the import commit are `risk:security` and are reviewed line by line. Tests drive the Vault's public export, inspect, plan and commit operations on real bootstrapped libraries with different App keys and check outcomes through the existing list, reveal, catalog and approval interfaces; there are no separate codec tests. The glossary, the feature inventory, both READMEs and the security policy describe backup when #274 makes it a current capability.
