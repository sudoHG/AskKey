# Issue workflow

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
5. **Implement only what the Scope allows.** If the card is unclear, the Scope is not enough, or Acceptance cannot be met: comment with the exact problem, add `needs-info`, and stop working on that issue. Do not guess. Then move on to the next claimable issue.
6. **Run every Acceptance command.** Put logs and other evidence in `~/Coding/AskKey-workspace/evidence/<number>/`, never in the repo.
7. **Commit** with a clear English message. Author identity: `sudoHG <by331works@gmail.com>`.
8. **Push the task branch and open a PR** with `Closes #<number>` and the receipt below. Add `needs-review` to the PR.
9. **Continue** with the next claimable issue until none remain.

**Tasks that produce no repository change** (for example, recording evidence from the legacy code): skip steps 7–8. Post the receipt as an issue comment instead and add `needs-review` to the issue. The planner closes it.

**Working in the legacy code**: a read-only reference clone of the archived repository is at `~/Coding/AskKey-workspace/legacy`, checked out at tag `legacy-final`. Create a detached worktree from it when a task needs to build or run legacy code:

```bash
git -C ~/Coding/AskKey-workspace/legacy worktree add --detach ~/Coding/AskKey-workspace/worktrees/legacy-<number> legacy-final
```

The `AGENTS.md` and other docs inside the legacy tree are outdated (they describe retired tools and processes). Ignore them; this repository's rules apply. Never fetch legacy history into this repository.

After a PR is merged, remove its worktree: `git worktree remove ~/Coding/AskKey-workspace/worktrees/<number>`.

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
5. Squash-merge, or leave numbered change requests and set `changes-requested`.

## Maintainer tasks

Issues labeled `ready-for-human` involve real data, the installed app, signing identities or account settings. Agents must not do them, even if they appear claimable.

## Removal tasks

Phase 3 issues remove whole capabilities. Unless the issue says otherwise:

1. **Authority**: remove exactly what the **Remove** rows of [docs/features.md](../features.md) list for the issue's area. Every **Keep** behavior must survive.
2. **Tests**: delete a test only if it exercises removed behavior exclusively. If a test mixes removed and kept behavior, delete only the removed assertions or setup. List every deleted test and every edited test in the receipt.
3. **No collateral changes**: no refactoring, renaming, moving or reformatting beyond what the removal requires.
4. **Strings**: remove `Localizable.xcstrings` entries that become unused (`scripts/sync-string-catalog.py` if it supports this; otherwise by hand, listed in the receipt).
5. **Hygiene baseline**: regenerate with `python3 scripts/check_hygiene.py --write-baseline`. The baseline may only shrink: delete entries, or lower a `debug` counter. Never add a path, a check or a higher count.
6. **Standard acceptance** (in addition to the issue's own):
   ```bash
   swift build
   swift test                                   # 0 failed; skips are a subset of the 5 baseline skips
   swift test list | sort > /tmp/after.txt      # diff against origin/main shows only deletions,
                                                # all inside test classes named in the receipt
   python3 -m unittest discover -s Tests/Automation -v
   python3 scripts/check_hygiene.py
   bash scripts/run-e2e.sh                      # all remaining required flows pass, 0 skipped
   ```
