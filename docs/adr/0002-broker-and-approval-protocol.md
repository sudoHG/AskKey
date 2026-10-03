# ADR 0002: Minimal Broker protocol and bound approvals

## Status

Accepted. Carries forward the retained Broker decisions of legacy ADR 0027.

## Context

Local agents need discovery, approved runtime delivery and separately approved writes while management stays in the App. Client-supplied identities cannot securely partition programs running as the same macOS user. The [security policy](../../SECURITY.md) states that boundary explicitly.

## Decision

- The App's local Broker exposes only metadata catalog, runtime execution, frozen credential write/upload/commit, request status/cancel, health and version operations. Permission/group management, access records, stored-value reveal, permanent deletion, local erase and resuming paused access remain authenticated App operations.
- Use the existing versioned, length-prefixed socket protocol. Incompatible versions fail closed. Frames, responses, fields, connections, request counts, queues and I/O deadlines have hard limits in [BrokerLimits](../../Sources/AskKeyBroker/BrokerLimits.swift).
- Bind approvals to operation ID, request ID, target, operation, immutable payload digest and deadlines. Query and cancellation require the request's unpredictable capability with its ID. Only an identical retransmission reuses an existing operation; changed content is rejected and a new operation requires a new ID. Denial creates no cooldown.
- Pending requests expire after five minutes or an earlier credential deadline. Approval can be consumed at most once for its bound payload. Timed allowances authorize reads of one credential globally for the local macOS user, never agent writes or one particular client. Read approval uses system authentication by default with an explicitly confirmed opt-out; every agent write still requires separate system authentication.
- Treat caller names, paths, signatures and purposes as unverified display context. Present approval independently of the management session; protect request details when the screen is locked. Opening or expiring management does not itself grant or revoke agent access.
- Preserve original authorization through the synchronized final launch check. Revocation, mutation, pause or expiry that wins this boundary prevents launch and cleans temporary material. Reallowing access cannot revive a consumed authorization. Once launch wins, revocation cannot retract delivered material or promise termination of that target.
- Commit agent CRUD and its operation receipt in one database transaction. External process execution does not have crash-level exactly-once semantics: retained completion receipts can return status without respawning, while an uncertain outcome is `outcome_unknown` and must not trigger automatic retry.

The current [RPC handler](../../Sources/AskKeyBroker/BrokerRequestHandler.swift), [approval state machine](../../Sources/AskKeyBroker/BrokerApprovalStateMachine.swift), [request binding](../../Sources/AskKeyBroker/BrokerApprovalStateMachine+Requests.swift), [approval decisions](../../Sources/AskKeyBroker/BrokerApprovalStateMachine+Decisions.swift) and [launch authorization](../../Sources/AskKeyBroker/BrokerApprovalStateMachine+RuntimeAuthorization.swift) implement the retained protocol and final-launch revision of legacy ADR 0027.

## Consequences

CLI and MCP cannot become management backdoors, and Allow remains Broker-mediated. A write approval or timed read allowance cannot authorize a different payload. Attribution helps the person decide but offers no verified per-agent identity. Availability depends on a successfully bootstrapped, running App with agent access active; authentication and cleanup failures must remain visible.
