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

## How work is handed out

The planner and the executors run inside Orca on the maintainer's Mac. Orca is the only coordination channel: the planner dispatches an issue to an executor, the executor asks blocking questions and reports completion through Orca, and the planner waits on those messages. The exact commands come from the version-matched guide, `orca skills get orchestration`; do not copy them from memory.

GitHub is the durable record, not a message bus. Issues hold the task cards, PRs hold the receipts and the review state, and CI is the acceptance gate. There are no status labels: an open PR means it is ready for review, a GitHub "Request changes" review means the executor has work to do, and questions go through Orca. The labels in [triage-labels.md](triage-labels.md) classify issues once; they are not updated as work progresses.

If Orca is unavailable, the maintainer tells an executor directly which issue to do. The steps below stay the same; only the question and completion messages are replaced by the conversation with the maintainer.

## Executor: doing a task

1. **Do only the dispatched issue.** The dispatch names it; read its Scope and Acceptance from the issue, not from the dispatch text.
2. **Work in the worktree Orca created** under `.worktrees/`, linked to the issue. Keep the branch name Orca assigned.
3. **Implement only what the Scope allows.** If the card is unclear, the Scope is not enough, or Acceptance cannot be met, use the `ask` command from the dispatch preamble and wait for the reply. Do not guess, and do not open a local prompt the coordinator cannot answer. An answer that changes Scope or Acceptance is written into the issue by the planner, so the issue stays the source of truth.
4. **Run every Acceptance command.** Keep logs and other artifacts only until you have read the results, then delete them. Never put them in the repo; report commands, counts and SHAs in the receipt.
5. **Commit** with a clear English message, using the identity your setup prescribes. No tool attribution lines.
6. **Push the branch and open a ready (non-draft) PR** with `Closes #<number>` and the receipt below.
7. **Send `worker_done`** with the PR URL and an explicit outcome, then end the turn and idle.
8. **Review rounds.** Change requests arrive as a follow-up dispatch in the same terminal. Address every numbered point, push, reply to the review on the PR, and send `worker_done` again.

**Tasks that produce no repository change** (for example, recording evidence from the legacy code): skip steps 5 and 6. Post the receipt as an issue comment instead; the planner closes the issue.

**Working in the legacy code**: the archived repository is `sudoHG/AskKey-legacy`, tagged `legacy-final`. When a task needs to read, build or run legacy code, clone that tag into a temporary directory outside this checkout and delete the clone when the task is done:

```bash
git clone --depth 1 --branch legacy-final https://github.com/sudoHG/AskKey-legacy.git "$(mktemp -d)/legacy"
```

The `AGENTS.md` and other docs inside the legacy tree are outdated (they describe retired tools and processes). Ignore them; this repository's rules apply. Never fetch legacy history into this repository.

After a PR is merged, the planner releases the worker and removes its worktree and local branch. The remote branch is deleted at merge.

## Receipt (PR description)

The PR template contains these sections. Fill all of them; write "None" when a section does not apply.

1. **Summary**: 3–5 lines.
2. **Diff stat**: summary of `git diff --stat origin/main`.
3. **Tests**: commands run; passed, failed and skipped counts; comparison with `main`.
4. **Checks**: results of every other Acceptance command.
5. **Deviations and questions**: anything that differs from the issue, and why.

## Planner: dispatching

1. Write the issues first; a dispatch never replaces a task card. The executor still reads Scope and Acceptance from the issue.
2. Create one Orca run per working session and start every independent `ready-for-agent` issue as its own worker in one wave; express `Blocked by` as task dependencies rather than dispatching one issue at a time. Each worker gets a fresh worktree created by Orca under `.worktrees/`, linked to its issue. No label is changed when an issue is dispatched.
3. Wait on `worker_done`, questions and escalations. Answer questions through Orca; if an answer changes Scope or Acceptance, edit the issue as well.
4. To request changes, leave a GitHub review with numbered points and send them as a follow-up dispatch to the same worker terminal instead of starting a new one.
5. After the PR is merged, release the worker and remove its worktree.

## Planner: review

1. CI red → request changes naming the failing step; stop.
2. Read the receipt; compare test counts and Acceptance results.
3. Run deterministic checks locally where useful.
4. Read the diff line by line only for `risk:security` changes and listed deviations. Verify move-only changes mechanically.
5. Either leave numbered change requests as a GitHub review, or report the PR as accepted to the maintainer. Merge (squash) only after the maintainer approves that PR; accepted PRs may be presented together in one approval request.

Changes to rule documents also go through a PR.

## Reviewer when the planner is unavailable

When the planner is offline, the maintainer may start a separate Codex session as reviewer. That session must not be the one that implemented the PR.

- Follow the review steps above and in [planner.md](planner.md) (CI → receipt → deterministic checks → line-by-line only for `risk:security` and listed deviations; `check_move_only.py` for move-only PRs).
- Do not write code, push to the task branch, merge, or change an issue's Scope or Acceptance. Request changes as a GitHub review with numbered points; the maintainer passes them to the executor.
- Report the verdict to the maintainer in Chinese: accepted or not, and the evidence (CI run, counts, checks run). The maintainer approves and merges.
- If an issue is unclear or a PR needs a decision outside its Scope, say so in the verdict and leave it for the planner or the maintainer instead of deciding.
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
