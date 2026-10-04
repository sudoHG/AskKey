# Issue workflow

This is the maintainer's internal workflow for the agents the maintainer runs. Outside contributors and their agents: follow [CONTRIBUTING.md](../../CONTRIBUTING.md) instead.

Work is tracked in GitHub Issues on `sudoHG/AskKey`. Each task issue is a self-contained task card.

## Task card fields

| Field | Meaning |
|---|---|
| Goal | One sentence. |
| Context | Files or docs to read first. |
| Scope | Paths that may be changed, and paths that must not be touched. |
| Steps | What to do. Move-only tasks say so explicitly. |
| Acceptance | Commands to run and the expected results. |
| Blocked by | Issues that must be closed first. |

Labels are described in [triage-labels.md](triage-labels.md).

## Executor: claiming and doing a task

Start every session with:

```bash
gh pr list --repo sudoHG/AskKey --label changes-requested --author @me
gh issue list --repo sudoHG/AskKey --label ready-for-agent --state open
```

1. **Review comments first.** If one of your PRs has `changes-requested`, address every numbered point, push, reply to the review, and swap the label back to `needs-review`.
2. **Pick the next issue.** Otherwise take the lowest-numbered open `ready-for-agent` issue whose `Blocked by` issues are all closed. Skip issues labeled `agent:claimed`.
3. **Claim it.** Replace `ready-for-agent` with `agent:claimed` and comment `Claimed.`
4. **Create a worktree** from the latest `main`:
   ```bash
   git fetch origin
   git worktree add ~/Coding/AskKey-workspace/worktrees/<number> -b task/<number>-<short-slug> origin/main
   ```
5. **Implement only what the Scope allows.** If the card is unclear, the Scope is not enough, or Acceptance cannot be met: comment with the exact problem, add `needs-info`, and stop working on that issue. Do not guess. Any question to the planner, in an issue or in a PR, must also add the `needs-info` label to that issue or PR; the planner's watcher triggers on labels, so a comment alone may go unseen. Then move on to the next claimable issue.
6. **Run every Acceptance command.** Keep logs and other artifacts only until you have read the results, then delete them. Never put them in the repo; report commands, counts and SHAs in the receipt.
7. **Commit** with a clear English message, using the identity your setup prescribes. No tool attribution lines.
8. **Push the task branch and open a ready (non-draft) PR** with `Closes #<number>` and the receipt below. Add `needs-review` to the PR.
9. **Continue** with the next claimable issue until none remain.

**Tasks that produce no repository change** (for example, recording evidence from the legacy code): skip steps 7–8. Post the receipt as an issue comment instead and add `needs-review` to the issue. The planner closes it.

**Working in the legacy code**: a read-only reference clone of the archived repository is at `~/Coding/AskKey-workspace/legacy`, checked out at tag `legacy-final`. Create a detached worktree from it when a task needs to build or run legacy code:

```bash
git -C ~/Coding/AskKey-workspace/legacy worktree add --detach ~/Coding/AskKey-workspace/worktrees/legacy-<number> legacy-final
```

The `AGENTS.md` and other docs inside the legacy tree are outdated (they describe retired tools and processes). Ignore them; this repository's rules apply. Never fetch legacy history into this repository.

After a PR is merged, clean up what the task created: `git worktree remove ~/Coding/AskKey-workspace/worktrees/<number>`, then `git branch -d task/<number>-<short-slug>`. The remote branch is deleted at merge.

## Receipt (PR description)

The PR template contains these sections. Fill all of them; write "None" when a section does not apply.

1. **Summary**: 3–5 lines.
2. **Diff stat**: summary of `git diff --stat origin/main`.
3. **Tests**: commands run; passed, failed and skipped counts; comparison with `main`.
4. **Checks**: results of every other Acceptance command.
5. **Deviations and questions**: anything that differs from the issue, and why.

## Planner: review

1. CI red → `changes-requested` with the failing step; stop.
2. Read the receipt; compare test counts and Acceptance results.
3. Run deterministic checks locally where useful.
4. Read the diff line by line only for `risk:security` changes and listed deviations. Verify move-only changes mechanically.
5. Either leave numbered change requests and set `changes-requested`, or report the PR as accepted to the maintainer. Merge (squash) only after the maintainer approves that PR; accepted PRs may be presented together in one approval request.

Changes to rule documents also go through a PR.

## Reviewer when the planner is unavailable

When the planner is offline, the maintainer may start a separate Codex session as reviewer. That session must not be the one that implemented the PR.

- Follow the review steps above and in [planner.md](planner.md) (CI → receipt → deterministic checks → line-by-line only for `risk:security` and listed deviations; `check_move_only.py` for move-only PRs).
- Do not write code, push to the task branch, merge, or change an issue's Scope or Acceptance. Request changes with numbered points and the `changes-requested` label; the executor fixes them.
- Report the verdict to the maintainer in Chinese: accepted or not, and the evidence (CI run, counts, checks run). The maintainer approves and merges.
- If an issue is unclear or a PR needs a decision outside its Scope, add `needs-info` and leave it for the planner or the maintainer instead of deciding.
- Start the verdict comment on the PR with `Review (stand-in reviewer):` so the planner can tell these reviews apart later.

## Maintainer tasks

Issues labeled `ready-for-human` involve real data, the installed app, signing identities or account settings. Agents must not do them, even if they appear claimable.

## Move-only tasks

Issues that move or split code without changing behavior say so in their Steps. Unless the issue says otherwise:

1. **Move only**: code moves between files or modules without behavior changes. No renames of types, members or files beyond what the issue lists; no reformatting; no comment rewrites.
2. **File layout**: one primary type per file, named after the type. Extensions that group one concern go to `Type+Concern.swift` next to the type. Keep each file at or under 600 lines.
3. **Access**: widen access only as far as the split requires (`private` → `fileprivate` is not enough across files, so use internal; across modules use `package`, never `public` unless the symbol was already public). List every widened symbol in the receipt.
4. **Verification**: run `python3 scripts/check_move_only.py origin/main` and paste its summary. Every non-trivial line removed must reappear; any added line that is not a header, import, access modifier or brace must be explained in the receipt.
5. **Hygiene**: split files must pass the `size` rule in `scripts/check_hygiene.py`; there is no baseline.
6. **Tests that read source files** (pre-approved, no need to ask): when a test reads a file that the split breaks up, update only its input so it reads every file that came from the original, in a deterministic order (a small test-only helper is fine). Keep test names, assertions, expected values and messages unchanged, and make the read fail if any listed file is missing. Enumerate these test-line deviations in the receipt; the `Sources`-only `check_move_only.py` run must still show no missing and no other lines. A test file that is already over 600 lines may receive only these input edits without being split here (the test-file split has its own issue).
   When a moved block contains an allowlisted `#if DEBUG`, update that file path in `DEBUG_ALLOWLIST` in `scripts/check_hygiene.py` (same number of entries, no new exceptions, checker behavior unchanged).
7. **Acceptance** (in addition to the issue's own): `swift build`, `swift test` with the same test list as main and 0 failed, Automation tests, hygiene, and green CI including `basic-ui-flows`.
