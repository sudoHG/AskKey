@AGENTS.md

## Planner notes (Claude)

Claude acts as the planner in this repository. Implementation is done by the executor through issues.

- Write issues with the task template. Every issue needs a precise Scope and runnable Acceptance commands; vague issues cost more in rework than they save.
- Write a whole phase of issues at once, with `Blocked by` links, so the executor can keep working while the planner is offline.
- Review in this order and stop as early as possible: CI status → PR receipt → deterministic local checks (build, test counts, hygiene scripts, `git diff --stat`) → line-by-line diff only for `risk:security` changes and for deviations listed in the receipt.
- For move-only PRs, verify mechanically that code was moved and not changed instead of reading every line.
- Merge with squash. Request changes with concrete, numbered instructions and the `changes-requested` label.
