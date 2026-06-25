# CONTEXT — git-ralph domain glossary

The vocabulary the harness and its skills should use. Keep titles, tests, and
proposals in these terms.

## Glossary

- **Harness** — the orchestrator script `scripts/ralph/ralph-gh.sh`. Owns the loop;
  agents never push/PR/close on their own.
- **Loop** — one pass picks at most one issue, runs it to a terminal outcome
  (finalized or `needs-human`), repeats up to `MAX_ITER`.
- **Issue selector** — pure logic that, given the open `ready-for-agent` and
  `plan-approved` issues, drops `blocked` and `awaiting-plan` ones, ranks `plan-approved`
  first, then by priority (`P0 < P1 < P2 < unlabelled`) then issue number, and returns
  the next issue number (or empty).
- **awaiting-plan** — a plan has been posted and the loop is waiting for a human to
  approve it. Skipped by the selector (like `blocked`) so the loop keeps draining other
  issues — UNLESS `plan-approved` is also present, which overrides the skip so a human
  can approve by simply adding the one label.
- **plan-approved** — a human approved the posted plan. The selector ranks these first
  and the loop skips the plan stage, going straight to implement against the vetted plan.
- **Worktree** — an isolated `git worktree` + branch (`agent/<n>-<slug>`) per issue,
  cut from `origin/main`. Created fresh or resumed if it already exists.
- **Agent runner** — the `claude`/`codex` abstraction that runs a prompt inside a worktree.
- **GATE 1 / validation gate** — runs `VALIDATE_CMD` (typecheck + tests) in the worktree.
- **GATE 2 / independent review** — a separate reviewer agent reads the diff and
  emits a **verdict** on its first line.
- **Verdict** — `REVIEW: PASS` or `REVIEW: FAIL`. Parsing is fail-safe: anything
  ambiguous is treated as `FAIL`.
- **Finalize** — the success path: commit → push → open draft PR (`Closes #n`) →
  close issue → remove worktree. Runs only when agent rc=0 AND GATE 1 AND GATE 2 pass.
- **needs-human** — the failure path: label the issue, comment the gate result codes,
  keep the worktree for inspection.
- **COMPLETE** — `<promise>COMPLETE</promise>`, printed when no `ready-for-agent`
  issues remain.

## Avoid

- "Story"/"prd.json" — superseded by GitHub issues. Do not reintroduce a local PRD file.
- "progress.txt" — superseded by issue/PR comments + this file.
