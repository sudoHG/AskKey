# ADR 0010: Approved agent credential metadata writes

## Status

Accepted. Amends [ADR 0002](0002-broker-and-approval-protocol.md).

## Context

Agents need to describe how a newly stored credential should be used and organize
it into a group. Usage instructions are guidance for later agents and therefore
an injection surface. Groups organize credentials and confer no authority, as
specified in [ADR 0001](0001-domain-storage-and-schema.md).

## Decision

- Agents may propose usage-instruction changes, group assignment, and group
  creation, rename and deletion as approved writes. #161 added instructions,
  assignment and creation; #162 added batch organization, including group rename
  and deletion. Permission changes, access records, stored-value
  reveal and local erase remain authenticated App operations.
- Every metadata write requires explicit write approval and separate system
  authentication. Allow permission and timed read allowances never authorize it.
  Hidden credentials remain absent from discovery and unwritable with the same
  generic unavailable response and hidden-guess recording.
- `create_credential` and `modify_credential` accept optional `usage_instructions`
  and `group`. Creation defaults to empty instructions and Ungrouped. Modification
  preserves omitted fields; empty instructions clear them and `group: null`
  unassigns the group. Component `changes` are optional on modification, but at
  least one component or metadata change is required. Text-only tools are unchanged.
- Instructions use the App's existing 4 KiB UTF-8 limit. Group names use
  `CredentialName.displayName`; matching uses NFC and case folding. A matching
  group retains its existing spelling. An unknown name creates a group only when
  the credential and operation receipt commit in the same transaction.
- Visible catalog items expose `group`, including explicit `null` for Ungrouped.
  The frozen approval shows instructions and group before and after, in full
  scrollable text, and marks proposed new groups. Viewing this catalog-visible
  metadata needs no reveal authentication. Both requested and resolved metadata
  are bound to the approval digest; changed retransmissions are rejected.
- These additive optional fields retain Broker protocol version 1. The helper
  ships with the App, so their versions match. Runtime delivery, permissions and
  client integration configuration are unchanged.

## Consequences

The user can inspect all proposed guidance before it affects future discovery.
Metadata-only writes preserve credential material and follow the same approval,
authentication, replay and atomic-commit boundaries as value writes. Group names
remain organizational data rather than grants of access.

## Batch organization approval shape (#162)

`organize_credentials` accepts 1–64 ordered operations: `move` (visible credential
name and a visible group name or `null`), `create_group`, `rename_group` (`from`
and `to`), and `delete_group`. A move may also name a group created earlier in
the batch. Create and rename reject catalog-visible occupied names, including
empty stored groups. Agent-invisible names freeze like absent names. The App
shows existing-group creation as a no-op and rename as a merge, with source and
target counts; renamed members reuse the target's existing spelling.
Deletion removes only the group and ungroups all members, including Hidden and
recycled members. Neither permissions nor credential deletion is available.

The App validates the entire sequence before freezing it. A new `.organize`
approval has an empty single-credential ID, the target `credential-library`,
and a sorted, unique `organizationCredentialIDs` binding. Single-credential
approvals require that binding to be absent. The request store retains one
ticket; equality, consumption and member revocation bind the whole batch. The
binding, operation summaries and affected-member counts are App-only and never
appear in submit, status, cancel, commit or error responses to agents. The
successful wire result contains only the operation ID.

The approval digest binds the ordered request and caller data, full before and
after states of affected records, and the spelling, existence and membership of
named groups, including full member states of an invisible target. Commit
revalidates these snapshots inside one SQL transaction that
persists all records, the group changes and the idempotency receipt. Unrelated
App group edits are preserved. Every stored-group writer reads, merges and
writes inside one SQL transaction; App create/delete also take the exclusive
agent-access gate. A changed affected record or named group rejects
the whole transaction. Existing Hidden members remain included; newly Hidden
members invalidate the frozen state. Only explicitly moved credentials must be
unexpired and can shorten the approval deadline. Rename/delete-only members,
including expired, Hidden and recycled members, do not shorten that deadline.

Allow and timed read allowances never approve organization. One explicit
approval and one system authentication cover the batch, with existing expiry,
denial, cancellation, exact retransmission and commit-retry behavior. A storage
failure rolls back every change without consuming the approval. Access records
use one existing `modify` event per distinct affected credential, including
Hidden members; a group-only batch records one credential-less `modify` event.
Denial, cancellation and request expiry use the same member binding.

The 300-point App card lists every numbered operation in order in a capped
scroll area, with from/to assignments and total/nonvisible counts for group
rename/deletion. There is no material reveal. Approve Organization and Deny
remain outside the scrolling area within the 680-point budget in English and
Simplified Chinese. The catalog returns a top-level `credentials` list and
`groups`: empty groups and groups with an active visible member. Hidden-only
and recycled-only groups are absent and use the existing generic not-found
response for operations requiring an existing visible group. Create and rename
targets reveal no invisible-group existence before approval. Cancellation is
serialized with organization commit and cannot cancel reserved consumption.
This additive tool keeps Broker protocol version 1 and leaves runtime
delivery and the App's group editor unchanged.
