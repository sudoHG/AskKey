# ADR 0004: Backup removed from v0.1

## Status

Accepted removal. A future backup design is deferred and requires its own issue; the legacy ADR 0029 implementation is not a current capability.

## Context

The maintainer judged iCloud backup and recovery not usable for v0.1. [Issue #18](https://github.com/sudoHG/AskKey/issues/18) removed that feature, its UI, recovery material, scheduling, launch compensation and entitlement requirements. Legacy ADR 0029 contains useful security constraints, but does not authorize restoring its implementation.

## Decision

- v0.1 provides no iCloud backup/recovery, recovery-key workflow, synchronization or manual backup export. Older backup-related files are ignored, not deleted or migrated. Local authenticated library erase remains a separate retained operation.
- Broker startup still depends on successful vault bootstrap and an active, usable library. Removing restore compensation does not weaken pause, lock, failure or approval-revocation behavior. Local erase still quiesces agent access, revokes grants, cleans delivered files and recovers interrupted local deletion with key deletion last.
- Any future backup proposal must define its contents, restore behavior, format compatibility and provider capability in a new issue. The minimum inherited security requirements are authenticated encryption before upload, independent high-entropy recovery material, no credential names in public filenames/metadata, and verification of a complete snapshot before replacement.
- It must handle partial publication, propagation order and corrupted snapshots using authenticated immutable generations and commit manifests or an equally justified design. Conflicting writers or forks need explicit human resolution rather than silent merging/overwriting; key rotation and retained historical material need clear ownership and separate deletion confirmation.
- Restore must require system authentication, protect the existing library with a recoverable atomic replacement, and complete recovery before agent service opens. Credentials must return to Ask, read authentication must be enabled and stale grants/deliveries must be invalidated. No claim of multi-device sync or forensic erasure follows from backup.

The removal and retained local lifecycle follow #18 and the [feature inventory](../features.md). The future constraints derive from legacy ADR 0029's authenticated generations, conflict handling, recovery and lifecycle consequences; they are design requirements, not shipped features or a chosen provider.

## Consequences

The current product has no built-in off-device recovery path. Backup errors and recovery state cannot complicate current startup or silently reenable agent access. A future implementation needs independent review and acceptance evidence rather than reusing an obsolete cloud contract as proof of readiness.
