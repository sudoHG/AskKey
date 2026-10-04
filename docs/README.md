# Documentation

Start with the [README](../README.md) for what AskKey does, then [architecture.md](architecture.md) for how the code is organized.

See the [changelog](../CHANGELOG.md) for release changes and known limitations.

## Guides

- [architecture.md](architecture.md): modules, allowed dependency directions, and the main flows through the App, Broker and helper.
- [client-integrations.md](client-integrations.md): how Claude Code, Codex, Cursor and Grok CLI are configured, verified and rolled back.
- [testing.md](testing.md): local checks, the Swift and Automation suites, and the desktop flows that run in CI.
- [glossary.md](glossary.md): domain terms with their Chinese UI labels.
- [features.md](features.md): the feature inventory recording what was kept or removed during normalization.

## Architecture decisions

- [ADR 0001](adr/0001-domain-storage-and-schema.md): credential domain, local storage and the v15 schema baseline.
- [ADR 0002](adr/0002-broker-and-approval-protocol.md): the Broker protocol and approval model.
- [ADR 0003](adr/0003-credential-delivery.md): runtime delivery through environment variables and temporary files.
- [ADR 0004](adr/0004-backup-removal-and-future-design.md): backup removed from v0.1 and constraints for a future design.
- [ADR 0005](adr/0005-distribution-and-client-integration.md): bundle layout, helper packaging and client adapters.
- [ADR 0006](adr/0006-release-process.md): locally signed, notarized DMG releases.
- [ADR 0007](adr/0007-claude-code-integration.md): Claude Code MCP setup through its CLI and the discovery hook in its settings.
- [ADR 0008](adr/0008-approval-shows-target.md): approvals show the command, working directory and delivered names.

## Contributing and project rules

- [CONTRIBUTING.md](../CONTRIBUTING.md): how to build, test and submit a pull request.
- [AGENTS.md](../AGENTS.md): rules for every AI agent working in this repository.
- [SECURITY.md](../SECURITY.md): security policy and private vulnerability reporting.
- [Maintainer workflow](agents/issue-workflow.md): the maintainer's internal issue workflow, with [planner notes](agents/planner.md) and [triage labels](agents/triage-labels.md).
