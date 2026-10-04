# Labels

## Triage

| Label | Meaning |
|---|---|
| `needs-triage` | Not yet assessed by the maintainer or planner. |
| `ready-for-agent` | Fully specified. The planner may dispatch it. |
| `ready-for-human` | Requires the maintainer in person: real data, the installed app, devices, signing or accounts. |
| `wontfix` | Decided not to do. |

## Status

Work status is not tracked with labels. Dispatch, questions and completion go through Orca; an open PR is ready for review, and a GitHub "Request changes" review means the executor has work to do. The labels `agent:claimed`, `needs-review`, `changes-requested` and `needs-info` are retired and must not be applied.

## Classification

| Label | Meaning |
|---|---|
| `phase:0` … `phase:8` | Normalization phase. |
| `risk:security` | Touches the broker, approval state machine, credential delivery, crypto or keychain. Reviewed line by line. |
| `bug`, `enhancement`, `documentation`, `accessibility`, `good first issue`, `help wanted` | Standard GitHub labels for public contributions. |
