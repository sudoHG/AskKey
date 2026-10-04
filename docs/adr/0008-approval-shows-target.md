# ADR 0008: Approvals show what will run

## Status

Accepted for v0.2 (#117). Refines the presentation in [ADR 0002](0002-broker-and-approval-protocol.md) and [ADR 0003](0003-credential-delivery.md). The helper-to-Broker protocol and its version are unchanged.

## Context

The approval prompt shows the caller name, the credential and the purpose; caller and purpose are self-declared. The person approving cannot see what will actually run. The data already exists: a runtime request (`BrokerTextRunRequest` in [TextRuntime](../../Sources/AskKeyBroker/TextRuntime.swift)) carries the command, arguments and working directory, and [Vault+CredentialDelivery](../../Sources/AskKeyVault/Vault+CredentialDelivery.swift) computes the approval's `payloadDigest` from that whole encoded request. The approval is therefore already bound to the exact command; it is only not displayed. Approval-tier values must not be decrypted before approval.

## Decision

- **Shown in the prompt** (approved design in #111): the executable and arguments, the working directory (home abbreviated to `~`), and the names the credential will be delivered as (environment variables and temporary-file variables). Values are never shown. The self-declared caller and purpose stay, marked unverified, inside a collapsed Details section.
- **Derived inside the App from the same request** whose digest the approval binds. A display summary is added to the App-internal approval request (`BrokerApprovalOperationRequest`) as optional, non-binding fields; it is computed in the Vault from the decoded run request, never sent by the helper as a separate claim, and never used for authorization. Equality and retransmission checks keep using the existing binding fields and digest.
- **Delivered names come from metadata only.** If the delivery mapping can be read without decrypting component values, show it. If the current storage keeps the mapping inside the encrypted value payload, do not decrypt before approval: show only the command and working directory in v0.2 and record a follow-up to store the mapping as separately encrypted metadata.
- **Display safety.** Arguments are rendered shell-quoted; control characters and newlines are escaped; the one-line summary is truncated in the middle at about 160 characters with the full text in Details; nothing from `inheritedEnvironment` is shown.
- **Persistence.** Access records store at most the executable's last path component (for example `deploy.sh`), never arguments or the working directory, because arguments may contain material the agent typed and records are kept for 90 days. Notifications follow the same rule.
- Write approvals (create, modify, delete) keep their existing frozen-content presentation.

## Consequences

The person approving sees the actual target with no protocol change and no new trust in self-declared fields. The display summary is held in App memory with its approval record, including the Broker's bounded terminal history (at most 256 entries, cleared when the App exits); it is never persisted beyond the sanitized executable name. Implementation: #118 (Vault and Broker side), #120 (prompt UI).
