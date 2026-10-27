# ADR 0008: Approvals show what will run

## Status

Accepted for v0.2 (#117). Refines the presentation in [ADR 0002](0002-broker-and-approval-protocol.md) and [ADR 0003](0003-credential-delivery.md). The helper-to-Broker protocol and its version are unchanged.

## Context

The approval prompt shows the caller name, the credential and the purpose; caller and purpose are self-declared. The runtime request (`BrokerTextRunRequest` in [TextRuntime](../../Sources/AskKeyBroker/TextRuntime.swift)) carries the command, arguments and working directory. [Vault+CredentialDelivery](../../Sources/AskKeyVault/Vault+CredentialDelivery.swift) binds that request and the App-derived component metadata into the read approval's `payloadDigest`. Approval-tier values must not be decrypted before approval.

## Decision

- **Shown in the prompt** (approved design in #111): the executable and arguments, the working directory (home abbreviated to `~`), and the names the credential will be delivered as (environment variables and temporary-file variables). Values are never shown. The self-declared caller and purpose stay, marked unverified, inside a collapsed Details section.
- **Derived and bound inside the App.** The read approval's `payloadDigest` hashes a domain-separated canonical encoding of the complete decoded run request, credential ID, and a digest of the ordered metadata projection (or an explicit unavailable sentinel). The optional display summary in `BrokerApprovalOperationRequest` stays presentation-only and never comes from a helper claim; it is derived from the same captured projection. Equality, retransmission and consumption keep using the existing binding fields and digest, so replacing a row with an older validly authenticated mapping invalidates the approval without a wire change.
- **Delivered names come from metadata only.** Text, file and bundle credentials store an independently encrypted versioned component list (#137), so catalog discovery and approval show delivery mappings without decrypting values. Bundle environment-variable and temporary-file names use the same display rules as single-material credentials. Unavailable metadata uses the explicit digest sentinel and omits names so Deny remains possible; it cannot pass delivery. After approval, delivery decrypts the payload and requires its ordered component names, kinds and mappings to equal the captured, approval-bound projection before delivering any of that credential's components. Completed-library marker failures are handled separately as documented in ADR 0001. The separate-metadata follow-up is implemented by #137.
- **Display safety.** Arguments are rendered shell-quoted; control characters and newlines are escaped, including component labels and delivery-variable names; the one-line summary is truncated in the middle at about 160 characters with the full text in Details; nothing from `inheritedEnvironment` is shown. Mapping validation accepts only complete ASCII variable identifiers, including rejecting trailing LF/CRLF. Bundle delivery rows label each mapping with its component name; single-material rows retain the credential name. Variable names prefer underscore breaks, with fallback opportunities every 12 characters within long words; the full name remains visible in Details. Display-only break controls never enter Copy, drag, Services or accessibility text.
- **Persistence.** Access records store at most the executable's last path component (for example `deploy.sh`), never arguments or the working directory, because arguments may contain material the agent typed and records are kept for 90 days. Notifications follow the same rule.
- Write approvals (create, modify, delete) keep their existing frozen-content presentation.

## Consequences

The person approving sees the actual target with no protocol change and no new trust in self-declared fields. The display summary is held in App memory with its approval record, including the Broker's bounded terminal history (at most 256 entries, cleared when the App exits); it is never persisted beyond the sanitized executable name. Implementation: #118 (Vault and Broker side), #120 (prompt UI).
