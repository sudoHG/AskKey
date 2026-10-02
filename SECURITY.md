# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository: open the **Security** tab, then select **Report a vulnerability**. You can also open the [private report form](https://github.com/sudoHG/AskKey/security/advisories/new).

Please keep security reports private rather than opening a public issue or pull request. Include:

- The affected commit on `main`, macOS version and relevant agent client/version.
- A description of the security boundary that failed, the expected behavior and the potential impact.
- Minimal reproduction steps using synthetic credentials and isolated test data.
- Relevant, sanitized error messages or logs, with sensitive values and identifying details removed.

Never include real credentials, recovery material, vault contents or client configuration contents, even in a private report. Use synthetic replacements in examples and inspect attachments before submitting them.

## Supported versions

No version has been released yet. Security reports currently apply to `main`; the project is under active restructuring before its first public release.

## Security boundaries

- Credentials are encrypted locally. Agents request access through the restricted `askkey` helper and the App's local Broker. **Allow**, **Ask** (the default) and **Hidden** are credential-wide permissions; Allow still requires Broker-mediated delivery.
- AskKey's management, MCP and helper responses do not return stored credential plaintext. Approved text values go to the selected target process; file values use short-lived private files. An approved target can print, copy or forward the material it receives.
- Caller-provided names, paths, signatures and purposes are display context, not verified identity or authorization. A timed read allowance applies globally to one credential for the local macOS user; it does not isolate one agent client from other programs running as that user.
- AskKey does not guarantee that another process running as the same macOS user cannot inspect or copy material after approved delivery. Hidden excludes a credential from the Agent catalog and access requests, but does not defend against same-user side channels.
- Approval is bound to the requested operation and frozen payload. Agent writes require a separate approval and commit the frozen content atomically; approval cannot be reused for a different operation or changed payload.
- Revocation, expiry and pause prevent delivery that has not passed the final launch authorization check and trigger temporary-file cleanup. They cannot retract material already received by a target. Agent access can be paused while management is locked or closed; resuming access requires system authentication and does not unlock management.

The [feature inventory](docs/features.md) records the retained behaviors and planned removals during restructuring. Report a suspected violation of these boundaries privately, including when the observed behavior differs from that inventory.
