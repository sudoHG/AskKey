# Planner notes

For the agent the maintainer runs as planner (see AGENTS.md → Maintainer's agent workflow). Other agents can ignore this file.

Claude acts as the planner in this repository. Implementation is done by the executor through issues.

- Write issues with the task template. Every issue needs a precise Scope and runnable Acceptance commands; vague issues cost more in rework than they save.
- Before publishing an issue, check that its Acceptance commands cannot be defeated by the rule documents themselves (for example a "no mentions" grep that would match `AGENTS.md`).
- Write related issues at once, with `Blocked by` links, so the executor can keep working while the planner is offline.
- Review in this order and stop as early as possible: CI status → PR receipt → deterministic local checks (build, test counts, hygiene scripts, `git diff --stat`) → line-by-line diff only for `risk:security` changes and for deviations listed in the receipt.
- For move-only PRs, verify mechanically that code was moved and not changed instead of reading every line.
- Never merge a PR or push `main` on your own. Report accepted PRs to the maintainer (in Chinese, batched when possible) and merge with squash only after explicit approval of those PRs. Rule-document changes also go through a PR.
- Request changes with concrete, numbered instructions and the `changes-requested` label.
- Delete review worktrees and temporary logs after reading their results.
- Watch labels (`needs-review`, `needs-info`) and executor comments that address the planner. Answer questions in the issue so the issue stays the source of truth.
- Write the remaining planned issues before going offline, so the executor and the stand-in reviewer (see issue-workflow.md → Reviewer when the planner is unavailable) can continue without you.
- When you come back, read PRs merged after stand-in reviews and open follow-up issues for anything that should have been caught.
