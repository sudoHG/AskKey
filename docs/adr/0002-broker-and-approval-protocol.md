# ADR 0002: Minimal Broker protocol and bound approvals

## Status

Accepted. Carries forward the retained Broker decisions of legacy ADR 0027.

[ADR 0010](0010-agent-credential-metadata-writes.md) amends the App-only group-management rule to allow approved agent metadata and group writes.

## Context

Local agents need discovery, approved runtime delivery and separately approved writes while management stays in the App. Client-supplied identities cannot securely partition programs running as the same macOS user. The [security policy](../../SECURITY.md) states that boundary explicitly.

## Decision

- The App's local Broker exposes only metadata catalog, runtime execution, frozen credential write/upload/commit, request status/cancel, health and version operations. Permission/group management, access records, stored-value reveal, permanent deletion, local erase and resuming paused access remain authenticated App operations.
- Use the existing versioned, length-prefixed socket protocol. Incompatible versions fail closed. Frames, responses, fields, connections, request counts, queues and I/O deadlines have hard limits in [BrokerLimits](../../Sources/AskKeyBroker/BrokerLimits.swift).
- Bind approvals to operation ID, request ID, target, operation, immutable payload digest and deadlines. Query and cancellation require the request's unpredictable capability with its ID. Only an identical retransmission reuses an existing operation; changed content is rejected and a new operation requires a new ID. Denial creates no cooldown.
- Pending requests expire after five minutes or an earlier credential deadline. Approval can be consumed at most once for its bound payload. Timed allowances authorize reads of one credential or an explicitly approved group snapshot (see the [group amendment](#amendment-group-timed-read-allowances-240)) globally for the local macOS user, never agent writes or one particular client. Read approval uses system authentication by default with an explicitly confirmed opt-out; every agent write still requires separate system authentication.
- Treat caller names, paths, signatures and purposes as unverified display context. Present approval independently of the management session; protect request details when the screen is locked. Opening or expiring management does not itself grant or revoke agent access.
- Preserve original authorization through the synchronized final launch check. Revocation, mutation, pause or expiry that wins this boundary prevents launch and cleans temporary material. Reallowing access cannot revive a consumed authorization. Once launch wins, revocation cannot retract delivered material or promise termination of that target.
- Commit agent CRUD and its operation receipt in one database transaction. External process execution does not have crash-level exactly-once semantics: retained completion receipts can return status without respawning, while an uncertain outcome is `outcome_unknown` and must not trigger automatic retry.

The current [RPC handler](../../Sources/AskKeyBroker/BrokerRequestHandler.swift), [approval state machine](../../Sources/AskKeyBroker/BrokerApprovalStateMachine.swift), [request binding](../../Sources/AskKeyBroker/BrokerApprovalStateMachine+Requests.swift), [approval decisions](../../Sources/AskKeyBroker/BrokerApprovalStateMachine+Decisions.swift) and [launch authorization](../../Sources/AskKeyBroker/BrokerApprovalStateMachine+RuntimeAuthorization.swift) implement the retained protocol and final-launch revision of legacy ADR 0027.

## Consequences

CLI and MCP cannot become management backdoors, and Allow remains Broker-mediated. A write approval or timed read allowance cannot authorize a different payload. Attribution helps the person decide but offers no verified per-agent identity. Availability depends on a successfully bootstrapped, running App with agent access active; authentication and cleanup failures must remain visible.

## Amendment: group timed read allowances (#240)

A grouped read may additionally grant one timed allowance for the exact credential snapshot listed in Details. The App freezes the group name, ordered credential IDs and names, component-metadata digests and credential deadlines from trusted metadata at submission. Only visible, unexpired credentials outside the Recycle Bin qualify. Credentials added later are never included. Allow and Hidden permissions retain their existing meaning, and writes always require separate approval.

The group option exists only while timed allowances are enabled and its snapshot remains valid. Every member is revalidated after authentication. A change to another member withdraws only the group option; the requested credential's single-read options remain available. Changes to the requested credential retain the existing cancellation rules. The front retains one subject title and one subtitle; Details lists every covered credential and explains when an earlier credential expiry limits the shared deadline.

One allowance record owns the snapshot and a common deadline, capped by the configured duration and the earliest member expiry. Expiry, explicit revocation from any member, revoke-all, pause, and screen lock, sleep and user switch once this process adopts the enabled End Timed Allow on Lock setting end the entire allowance. A member's metadata, permission or group change removes that member alone from an already granted allowance. Overlapping new grants replace only overlapping memberships without extending other members. Before replacement, cancel older unconsumed timed approvals and invalidate timed runtime authorizations for those credentials under the same approval lock; once-only approvals and non-overlapping credentials retain their authority, except a prepared run that also contains a replaced timed credential is cancelled as a whole. The allowance list presents a group grant once and revokes it as a whole. Existing final-launch authorization and cleanup guarantees apply to every member; the Broker wire protocol is unchanged.

## Amendment: End Timed Allow on Lock (#241)

The setting is off by default and requires ownership and system authentication to change in either direction. Once this process adopts it as enabled, screen lock, sleep and user switch end all single and group timed allowances, cancel unconsumed timed approvals and invalidate prepared timed runtime authorizations. Sleep starts at willSleep; user switch is session resign. A remote opt-in not yet adopted is checked at the next ending event through a Keychain policy read (which can fail) or at the next agent request. New timed grants are refused while locked, asleep or switched out, including when the screen state is unknown. Pending requests, once-only approvals, Allow credentials and the management session keep their existing behavior, except a prepared run that also contains a timed credential is cancelled as a whole. Disabling the setting cannot revive revoked authority.

The Broker owns the sleep transition. willSleep records the upper bound of the continuous-minus-absolute clock offset. didWake clears sleep unconditionally; otherwise an unlocked sample clears it only when the current lower bound exceeds that saved upper bound, proving real sleep despite a missed wake. The bounds rely on in-order absolute, continuous and absolute counter reads. A lock/unlock cycle before that proof cannot clear sleeping, and waking cannot clear session suspension. Session generation changes and final timed grants share the approval lock, preventing an in-flight decision from restoring ended authority even after the session resumes. Live screen checks backstop delayed or missing lock notifications only when the setting is enabled.

Aborted sleep without didWake keeps new timed grants blocked until didWake, unless a later unlocked sample proves a subsequent real sleep (fail-closed).

The [allowance revocation](../../Sources/AskKeyBroker/BrokerApprovalStateMachine+Allowances.swift), [screen and sleep checks](../../Sources/AskKeyBroker/BrokerApprovalStateMachine+ScreenSession.swift) and [runtime authorization](../../Sources/AskKeyBroker/BrokerApprovalStateMachine+RuntimeAuthorization.swift) implement these boundaries. [ApprovalStateMachinePolicyTests](../../Tests/AskKeyBrokerTests/ApprovalStateMachinePolicyTests.swift) checks the clock bounds, [GroupTimedAllowanceTests](../../Tests/AskKeyBrokerTests/GroupTimedAllowanceTests.swift) checks whole-group runtime revocation, and [GroupTimedAllowanceSessionTests](../../Tests/AskKeyAppTests/GroupTimedAllowanceSessionTests.swift) checks session events, mixed runs and Vault group revalidation.
