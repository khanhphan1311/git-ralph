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
  plan and the harness posts it to the issue as the **canonical** record (an
  `<!-- ralph:plan -->` comment). In **semi** mode (default) the issue is parked on
  `awaiting-plan` for human approval; with `AUTO_PLAN=1` the plan is auto-approved and
  implementation proceeds inline. The implement stage reads the approved plan back from
  that comment (#21 Delta A).
- **AUTO_PLAN** — `1` skips human plan approval (full-auto to the gate); `0` (default) is
  semi mode. The plan is posted to the issue either way, for audit.
- **Per-stage model** — `PLAN_MODEL` (strong reasoner) for Plan, `CODE_MODEL`
  (cheaper/faster) for Implement, routed via `model_flag` at each `claude` call. The gate
  stages run on no-mistakes' own repo-configured agent, so there is no harness-side model
  for them (#21 Delta B).
- **Agent runner** — the `claude`/`codex` abstraction that runs a prompt (optionally with
  a per-stage model) inside a worktree.
- **Gate** — [no-mistakes](https://github.com/kunchenguid/no-mistakes), the backend that
  replaced GATE 1 + GATE 2 + push + PR (#23). One headless `no-mistakes axi run` drives a
  fixed pipeline — `intent → rebase → review → test → document → lint → push → pr → ci` —
  with its own auto-fix loop, then stops at a terminal **outcome**. The harness never
  parses a verdict or pushes/opens PRs itself.
- **axi run** — `no-mistakes axi run --intent "<goal>" --yes`. `--intent` is the issue's
  goal/decisions (not a diff summary); `--yes` is git-ralph's autonomous mode (auto-resolve
  every gate). The gate validates in its OWN worktree (`~/.no-mistakes/worktrees/`),
  independent of git-ralph's.
- **Outcome** — the terminal token parsed from `axi run` TOON (fail-safe → `failed`):
  `checks-passed` (CI green, PR open, awaiting human merge), `passed` (PR merged),
  `failed`/`cancelled` (escalate). A `gate:` block means a semi-mode approval pause.
- **Finalize** — the success path for `checks-passed`: ensure the PR carries `Closes #n`,
  comment + drop the agent label, remove git-ralph's worktree. The issue stays OPEN and
  the PR waits for a human; git-ralph never merges.
- **needs-human** — the failure/escalation path: reap any orphaned gate run (`axi abort`),
  label the issue, comment where to look (`axi status` / `axi logs`), keep the worktree.
- **COMPLETE** — `<promise>COMPLETE</promise>`, printed when no `ready-for-agent`
  issues remain.

## Avoid

- "Story"/"prd.json" — superseded by GitHub issues. Do not reintroduce a local PRD file.
- "progress.txt" — superseded by issue/PR comments + this file.
