# Labels

## Triage

| Label | Meaning |
|---|---|
| `needs-triage` | Not yet assessed by the maintainer or planner. |
| `needs-info` | Blocked on a question. The latest comment states what is missing. |
| `ready-for-agent` | Fully specified. An agent may claim it. |
| `ready-for-human` | Requires the maintainer in person: real data, the installed app, devices, signing or accounts. |
| `wontfix` | Decided not to do. |

## Status

| Label | Meaning |
|---|---|
| `agent:claimed` | An agent is working on the issue. |
| `needs-review` | The PR is ready for planner review. |
| `changes-requested` | Review asked for changes. The executor handles these before claiming new work. |

## Classification

| Label | Meaning |
|---|---|
| `phase:0` … `phase:8` | Normalization phase. |
| `risk:security` | Touches the broker, approval state machine, credential delivery, crypto or keychain. Reviewed line by line. |
| `bug`, `enhancement`, `documentation`, `accessibility`, `good first issue`, `help wanted` | Standard GitHub labels for public contributions. |
