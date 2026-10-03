# ADR 0001: Credential domain, local storage and the v15 baseline

## Status

Accepted. Records the current product, replacing the obsolete upgrade portions of legacy ADR 0026.

## Context

AskKey needs a single authorization object and must open supported existing libraries without importing the old Project/Environment model. The legacy v15 schema is the compatibility baseline. [Issue #31](https://github.com/sudoHG/AskKey/issues/31), including its interrupted-creation rules and atomic-creation addendum, supersedes the old staged Lokalite upgrade design.

## Decision

- A globally named credential contains text, file bytes or multiple components and has one Allow, Ask or Hidden permission; Ask is the default. Groups organize credentials and confer no authority. Display names are trimmed; uniqueness uses NFC and Unicode case folding. There is no folder association or current-directory inference.
- Store sensitive fields with authenticated encryption, authenticate each credential record together with its policy, and use a keyed normalized-name index. The App owns the vault key; the helper never opens the database or loads that key. Opening the library for agent service does not create an authenticated management session.
- `askkey-0001-baseline` preserves the v15 CREATE statements. Adoption accepts exactly the 14 ordered v15 migration identifiers with matching normalized schema and valid App-key authentication, then replaces only migration history in one transaction. Already normalized libraries are validated without repeating adoption.
- The current schema also includes `askkey-0002-drop-legacy-tables`: drop the five old domain tables only if they contain nothing beyond the `Default` seed; otherwise preserve every old table and row and still record the migration. New libraries finish at both AskKey identifiers. Old tables retained for data preservation do not restore old product APIs.
- With no database or key, create a new library. With an App key, require its supported current database and never fall back to a pending key. With only a valid 32-byte pending key, resume creation only if the current database is absent without orphaned current sidecars, or its contents exactly match an unfinished first creation at the supported baseline/current schema. Extra rows, unknown history, mismatched schema and other unverifiable states fail closed.
- Build first creation at `credentials-v2.db.creating`, checkpoint and close it, set `0600`, synchronize it and rename exclusively to `credentials-v2.db`. Synchronize the database and its directory chain before promoting the pending key, then delete that pending key. Cleanup owns only the `.creating` file and its sidecars. A crash after publication but before promotion is recoverable by the unfinished-creation rule.
- Successful opens tighten the directory to `0700` and the database to `0600`. Stale pending-key deletion is best effort; for an empty App-key library, a different or unreadable pending key is preserved. Historical databases, migration journals and `.pending*` siblings are not opening inputs and are never read, moved, rewritten or deleted by bootstrap.

These decisions follow legacy ADR 0026's domain, naming, encryption and folder-removal sections, #31, the legacy-table removal in [#33](https://github.com/sudoHG/AskKey/issues/33) and the directory durability follow-up in [#43](https://github.com/sudoHG/AskKey/issues/43). Current evidence is the [schema implementation](../../Sources/AskKeyVault/Storage/VaultStoreMigrations.swift), [bootstrap](../../Sources/AskKeyVault/Migration/VaultBootstrap.swift), [record authentication](../../Sources/AskKeyVault/Crypto/CredentialRecordAuthentication.swift) and [name index](../../Sources/AskKeyVault/Models/CredentialName.swift).

## Consequences

Supported libraries retain their credentials, permissions, ciphertext and receipts. Unsupported states require diagnosis rather than a guessed upgrade or a silently replaced key. Pending keys authorize only a provably empty interrupted creation, never legacy v15 adoption. AskKey assumes the App is the sole library opener; file preflight is defense in depth, not protection against a hostile same-user process changing files concurrently.
