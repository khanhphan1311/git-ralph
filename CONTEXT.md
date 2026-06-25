# CONTEXT — git-ralph domain glossary

The vocabulary the harness and its skills should use. Keep titles, tests, and
proposals in these terms.

## Glossary

- **Harness** — the orchestrator script `scripts/ralph/ralph-gh.sh`. Owns the loop;
  agents never push/PR/close on their own.
- **Loop** — one pass picks at most one issue, runs it to a terminal outcome
  (finalized or `needs-human`), repeats up to `MAX_ITER`.
- **Issue selector** — pure logic that, given the open `ready-for-agent` issues,
  drops `blocked` ones, sorts by priority (`P0 < P1 < P2 < unlabelled`) then issue
  number, and returns the next issue number (or empty).
- **Worktree** — an isolated `git worktree` + branch (`agent/<n>-<slug>`) per issue,
  cut from `origin/main`. Created fresh or resumed if it already exists.
- **Agent runner** — the `claude`/`codex` abstraction that runs a prompt inside a worktree.
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
