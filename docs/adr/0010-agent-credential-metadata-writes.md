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
  creation, rename and deletion as approved writes. Group rename and deletion
  through a batch tool are deferred to #162; #161 implements instructions,
  assignment and creation only. Permission changes, access records, stored-value
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
