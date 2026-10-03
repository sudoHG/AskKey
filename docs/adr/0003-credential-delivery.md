# ADR 0003: Explicit runtime delivery and frozen agent writes

## Status

Accepted. Carries forward the retained delivery decisions of legacy ADR 0028 and the final launch boundary of ADR 0027.

## Context

An agent should use a selected credential without receiving stored plaintext in AskKey's own responses. A target that receives approved material can still print, copy or forward it; another process running as the same macOS user may inspect it. This is a delivery boundary, not containment of the target.

## Decision

- Require an explicit command and the smallest explicitly selected credential set; there is no inject-all default. Validate and authorize the whole set before delivering it. Text components use selected environment-variable mappings; file components use temporary-file mappings, and components marked undelivered are omitted. A credential remains one authorization unit.
- `askkey run` is a non-PTY executor. The Broker launches the target with bounded, allowlisted inherited environment and receives command, arguments, working directory and standard-stream descriptors from the helper. CLI target streams connect directly to those descriptors; the helper does not read the output, forwards cancellation/signals and returns the target's exit status. Programs that require a PTY are not guaranteed.
- MCP run discards target output and returns execution or approval status. Stored credential values never appear in AskKey's catalog, management RPC, errors, notifications or logs. CLI target output is external output after approved release and may contain the delivered value.
- Import only ordinary files, freezing bytes, original filename, size and digest with size and read-consistency checks; reject links, directories and special files. Materialize random `0600` files in a private `0700` directory. File lifetime is at most five minutes and no later than credential expiry or the original approval deadline.
- Apply the synchronized final launch authorization from [ADR 0002](0002-broker-and-approval-protocol.md) to text, file and mixed sets, including files being generated when revocation occurs. Clean material on failed launch, target completion, TTL, pause, revocation, mutation, hiding, expiry, vault lock, exit and startup sweep. Failed deletion stays visible and is retried; delivery does not promise forensic erasure or retraction from a target.
- An agent may submit new values it already knows. Helper/MCP buffers can transiently contain them but must not persist, log or echo them. Upload files as bounded, ordered byte chunks rather than mutable paths; freeze the actual bytes and digest before approval, then commit only that payload atomically with its receipt.
- Mask write contents by default. Viewing the exact frozen payload needs separate system authentication and does not approve it. Material that must remain unknown to an agent must be entered or changed by the person in the App.

Current evidence includes [credential delivery](../../Sources/AskKeyVault/Vault+CredentialDelivery.swift), [file lifecycle](../../Sources/AskKeyVault/FileDeliveryManager.swift), [runtime streams and receipts](../../Sources/AskKeyBroker/TextRuntime.swift), [MCP run](../../Sources/AskKeyHelper/MCPTools.swift), [file upload freezing](../../Sources/AskKeyBroker/BrokerFileWriteCoordinator+Uploads.swift) and [write commit](../../Sources/AskKeyVault/Vault+AgentWriteCommit.swift).

## Consequences

Agents receive useful status and metadata while targets receive only configured material. File cleanup and launch checks share the original authorization deadline, so expired paths cannot justify a new launch. Completed receipts avoid duplicate execution; unknown outcomes require investigation rather than automatic replay. Approved targets and same-user processes remain outside AskKey's confidentiality guarantee after delivery.
