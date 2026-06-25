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
- **Plan stage** — between worktree and implement, a `PLAN_MODEL` agent writes a short
  plan and the harness posts it to the issue as the **canonical** record (an `<!-- ralph:plan -->`
  comment). In **semi** mode (default) the issue is parked on `awaiting-plan` for human
  approval; with `AUTO_PLAN=1` the plan is auto-approved and implementation proceeds
  inline. The implement stage reads the approved plan back from that comment.
- **AUTO_PLAN** — `1` skips human plan approval (full-auto to draft PR); `0` (default) is
  semi mode. The plan is posted to the issue either way, for audit.
- **Agent runner** — the `claude`/`codex` abstraction that runs a prompt inside a worktree.
- **GATE 1 / validation gate** — runs `VALIDATE_CMD` (typecheck + tests) in the worktree.
- **GATE 2 / review→remediate loop** — after GATE 1 and opening the draft PR, an
  independent `REVIEW_MODEL` reviewer reads the diff and emits **scoped findings**. The
  loop auto-fixes in-scope findings, files out-of-scope ones, and re-reviews — up to
  `REVIEW_MAX_ITER` rounds — until `review_status` is `CLEAN`.
- **Scoped finding** — a single review issue tagged `scope: "in"` (caused by this diff:
  bug, missing test, acceptance-criteria miss, regression, leaked secret) or
  `scope: "out"` (pre-existing / unrelated / belongs to another issue). Emitted by the
  reviewer as a JSON array inside a ` ```json ` block (#21 Delta C).
- **review_status** — pure classifier over reviewer output: `REMEDIATE` (>=1 in-scope
  finding → auto-fix), `CLEAN` (no in-scope findings, or a bare `REVIEW: CLEAN` line),
  or `UNCLEAN` (fail-safe: broken/missing findings JSON — never clears the PR).
- **Remediate** — feed the in-scope findings to a `CODE_MODEL` agent to fix on the same
  branch, re-run GATE 1, push, and re-review. In-scope = auto-fixed; out-of-scope = filed
  as new `needs-triage` issues that do NOT block the current PR.
- **REVIEW_MAX_ITER** — cap (default 3) on review→remediate rounds. Reaching it with
  in-scope findings still present → `needs-human` (worktree kept).
- **Finalize (clean)** — the success path once review is CLEAN: comment → drop agent
  label → close issue → remove worktree. The **draft PR is left for a human to merge**
  (no auto-undraft / auto-merge). The draft PR itself is opened earlier, at stage 5.
- **needs-human** — the failure path: label the issue, comment the reason,
  keep the worktree for inspection.
- **COMPLETE** — `<promise>COMPLETE</promise>`, printed when no `ready-for-agent`
  issues remain.

## Avoid

- "Story"/"prd.json" — superseded by GitHub issues. Do not reintroduce a local PRD file.
- "progress.txt" — superseded by issue/PR comments + this file.
