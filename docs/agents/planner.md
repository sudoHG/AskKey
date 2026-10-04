# Planner notes

For the agent the maintainer runs as planner (see AGENTS.md → Maintainer's agent workflow). Other agents can ignore this file.

Claude acts as the planner in this repository. Implementation is done by executors that the planner dispatches through Orca (see issue-workflow.md → How work is handed out); the issues remain the task cards.

- Write issues with the task template. Every issue needs a precise Scope and runnable Acceptance commands; vague issues cost more in rework than they save.
- Before publishing an issue, check that its Acceptance commands cannot be defeated by the rule documents themselves (for example a "no mentions" grep that would match `AGENTS.md`).
- Write related issues at once, with `Blocked by` links, and dispatch every independent issue in one wave. Issues written ahead also let the maintainer hand work to an executor directly while the planner is offline.
- Review in this order and stop as early as possible: CI status → PR receipt → deterministic local checks (build, test counts, hygiene scripts, `git diff --stat`) → line-by-line diff only for `risk:security` changes and for deviations listed in the receipt.
- For move-only PRs, verify mechanically that code was moved and not changed instead of reading every line.
- Never merge a PR or push `main` on your own. Report accepted PRs to the maintainer (in Chinese, batched when possible) and merge with squash only after explicit approval of those PRs. Rule-document changes also go through a PR.
- Request changes as a GitHub review with concrete, numbered instructions, and dispatch them to the same worker through Orca.
- Delete review worktrees and temporary logs after reading their results. After a merge, release the worker and remove its worktree.
- Wait on Orca messages (`worker_done`, questions, escalations) rather than polling GitHub. Answer questions through Orca, and edit the issue whenever the answer changes Scope or Acceptance, so the issue stays the source of truth. Do not use labels to signal progress.
- Write the remaining planned issues before going offline, so the executor and the stand-in reviewer (see issue-workflow.md → Reviewer when the planner is unavailable) can continue without you.
- When you come back, read PRs merged after stand-in reviews and open follow-up issues for anything that should have been caught.
