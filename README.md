# git-ralph

An autonomous AI agent loop that pulls tasks from **GitHub Issues**, isolates each
one in a **git worktree/branch**, has an AI coding tool implement a single vertical
slice, then hands the branch to the **[no-mistakes](https://github.com/kunchenguid/no-mistakes)
gate** — one `axi run` drives review → test → document → lint → push → pr → ci with its
own auto-fix loop — and stops at an **outcome**, leaving the open PR for a human to merge.
Each issue is handled in a fresh agent context; memory persists via git history,
issue/PR comments, and `CONTEXT.md`/`AGENTS.md`.

A GitHub-issue/PR-driven fork of [snarktank/ralph](https://github.com/snarktank/ralph),
based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/), layered with
the [mattpocock/skills](https://github.com/mattpocock/skills) engineering skills.

## How this differs from snarktank/ralph

| snarktank/ralph (original)        | git-ralph (this fork)                                     |
| --------------------------------- | --------------------------------------------------------- |
| Source of truth = `prd.json`      | Source of truth = **GitHub issues** (PRD + sub-issues)    |
| One feature branch, sequential    | **One git worktree + branch per issue** (parallelisable)  |
| `passes: false/true` in JSON      | Issue `open` + `ready-for-agent` / issue `closed`         |
| Priority field in JSON            | Labels `P0`/`P1`/`P2`                                      |
| `progress.txt`                    | Issue/PR comments + `CONTEXT.md`/`AGENTS.md`              |
| Commit on a story                 | implement → **no-mistakes `axi run`** → PR for a human    |
| Typecheck/test gate               | **no-mistakes gate** (review/test/lint/doc/push/pr/ci)    |

The orchestrator is a standalone script (`scripts/ralph/ralph-gh.sh`). It does **not**
patch the original `ralph.sh` — see [SYNC.md](./SYNC.md) for why that keeps upstream
merges conflict-free.

## Architecture

```
/to-prd → /to-issues (mattpocock)   ──▶  GitHub Issues (PRD + sub-issues, label ready-for-agent)
                                                  │
                  ┌───────────────────────────────┘
                  ▼
  ralph-gh.sh loop:  select highest-priority ready-for-agent issue, not blocked
                  │
        git worktree add -B agent/<n>-<slug>   (isolation, from origin/BASE_BRANCH)
                  │
        agent (claude -p) implements ──▶  skills: tdd / diagnosing-bugs / domain-modeling
                  │
        commit ──▶  no-mistakes axi run --intent "<issue goal>" --yes
                    └─ intent → rebase → review → test → document → lint → push → pr → ci
                       (its own auto-fix loop; validates in its OWN worktree)
                  │
        checks-passed → ensure PR has Closes #n → comment/unlabel → remove worktree (PR waits for human)
        passed        → PR merged → close issue → remove worktree
        failed/cancelled → axi abort → label needs-human → keep worktree for a human
                  │
        no ready-for-agent issues left → <promise>COMPLETE</promise>
```

## Prerequisites

| Tool         | Why                                  | Check                            |
| ------------ | ------------------------------------ | -------------------------------- |
| `gh` (auth)  | Issues, PRs, labels                  | `gh auth status` (scope: `repo`) |
| `git` ≥ 2.30 | `git worktree` per-issue isolation   | `git --version`                  |
| `jq`         | Issue-selection priority logic       | `jq --version`                   |
| `claude`     | Default agent backend                | `claude --version`               |
| `no-mistakes`| The gate (review/test/lint/push/pr/ci) | `no-mistakes doctor`           |
| `bats`       | The harness's own test suite (dev)   | `npx bats --version`             |
| `codex`      | Optional alt backend (`AGENT=codex`) | `codex --version`                |

You also need a **target git repository** with a remote `origin` on GitHub and
permission to create labels, issues, and PRs on it.

## Setup

git-ralph is **one clone you reuse for every project** — you don't re-clone it per repo,
just `git pull` to pick up updates. The split between machine-wide and per-project setup:

**Once per machine**
- Install `no-mistakes` (binary + shared daemon) — see "Set up the no-mistakes gate" below.
- Clone git-ralph once; keep it current with `git pull`.

**Once per target project** (run from inside that repo's clone)
1. `bash /path/to/git-ralph/scripts/setup-no-mistakes.sh` — `no-mistakes init` for this repo
   (its own gate; the daemon is shared).
2. Commit a **project-specific `.no-mistakes.yaml`** to its **default branch**, with that
   project's own `commands.test`. Do **not** copy git-ralph's — that file gates git-ralph itself.
3. `REPO=<owner/repo> bash /path/to/git-ralph/scripts/setup-labels.sh` — operational labels.
4. `/setup-matt-pocock-skills` (issue tracker = GitHub) — seed the engineering skills.

Then run the loop from inside the project (Option 1). The sections below expand each step.

### Option 1 — Point the harness at any repo (no vendoring)

All `git`/`gh` operations run against the **current working directory**, and prompts
are read from the harness's own folder. So you can run the harness against any repo by
invoking the script from inside that repo's clone and overriding a few env vars:

```bash
cd /path/to/your/target/repo

# One-time: stand up the no-mistakes gate (idempotent), then commit .no-mistakes.yaml to main
bash /path/to/git-ralph/scripts/setup-no-mistakes.sh

BASE_BRANCH=main \                                  # your repo's default branch
WORKTREE_ROOT=../your-repo-worktrees \              # where per-issue worktrees go
MAX_ITER=1 \
bash /path/to/git-ralph/scripts/ralph/ralph-gh.sh 1
```

`REPO` auto-resolves from the target's `origin` remote. Use this for quick runs. The
test command lives in `.no-mistakes.yaml` (`commands.test`), not an env var — see
"Configuration".

### Option 2 — Vendor into your project (permanent)

Copy the harness into the target repo so it's versioned alongside the code and the
team/CI can use it:

```bash
# From the target repo root
mkdir -p scripts/ralph
cp -r /path/to/git-ralph/scripts/ralph/* scripts/ralph/
cp /path/to/git-ralph/scripts/setup-labels.sh scripts/
chmod +x scripts/ralph/ralph-gh.sh scripts/setup-labels.sh
```

Then customise `scripts/ralph/prompts/build.md` and `.no-mistakes.yaml` for your stack.

### Configure the mattpocock skills (once per repo)

The harness drives a backlog produced by the mattpocock engineering skills. Install
them in `~/.claude/skills/` (global) or `.claude/skills/` (per-repo), then run:

```
/setup-matt-pocock-skills
```

Choose **issue tracker = GitHub**. This writes an `## Agent skills` block into
`AGENTS.md`/`CLAUDE.md` and seeds `docs/agents/` so `to-prd`, `to-issues`, `triage`,
`tdd`, and `diagnosing-bugs` know your repo's conventions.

### Create the operational labels (once per repo)

```bash
REPO=<owner/repo> bash scripts/setup-labels.sh
```

Creates `ready-for-agent`, `needs-human`, `blocked`, `P0`/`P1`/`P2`, and the canonical
triage labels. Idempotent — safe to re-run.

### Set up the no-mistakes gate (once per repo)

```bash
bash scripts/setup-no-mistakes.sh        # runs `no-mistakes init` + ensures the daemon
```

Initializes the local bare gate, installs the `/no-mistakes` agent skill, and starts the
daemon. Idempotent. Then **commit `.no-mistakes.yaml` to the default branch** — the daemon
reads `commands.test`/`agent` only from `main` (supply-chain hardening), never from a gated
feature branch. Install the binary first if needed (`no-mistakes doctor` to verify):

```bash
# macOS/Linux
curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh
# Windows (PowerShell)
irm https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.ps1 | iex
```

## Workflow

### 1. Create a backlog

In Claude Code, in the target repo:

```
# Turn a conversation/spec into a parent PRD issue on GitHub:
/to-prd  <describe your feature>

# Split the PRD into independently-grabbable vertical-slice sub-issues,
# each labelled ready-for-agent + a priority:
/to-issues  break PRD #<n> into issues, label ready-for-agent + P0/P1/P2
```

### 2. Run the loop

```bash
# Dry-run: print the issue the selector would pick, change nothing
DRY_RUN=1 bash scripts/ralph/ralph-gh.sh

# One issue, one pass (recommended first run)
MAX_ITER=1 bash scripts/ralph/ralph-gh.sh 1

# Drain the backlog (up to N iterations)
bash scripts/ralph/ralph-gh.sh 20
```

### 3. What happens each iteration

1. Select the next issue: `plan-approved` first, then the highest-priority open
   `ready-for-agent` that is not `blocked`/`awaiting-plan` (`P0 < P1 < P2 < unlabelled`,
   ties broken by issue number).
2. Create — or resume — a worktree + branch `agent/<n>-<slug>` from `origin/BASE_BRANCH`.
3. **Plan** (fresh issues only; `plan-approved` issues skip to 4) — a `PLAN_MODEL` agent
   writes a short plan, posted to the issue as the canonical `<!-- ralph:plan -->` comment.
   - **Semi** (default, `AUTO_PLAN=0`): park the issue on `awaiting-plan` and move on; a
     human approves by adding `plan-approved`.
   - **Full-auto** (`AUTO_PLAN=1`): auto-approve and implement inline.
4. Run the implement agent (`CODE_MODEL`) with `prompts/build.md` + the approved plan +
   the issue body & comments, then commit.
5. **Gate** — `no-mistakes axi run --intent "<issue goal>" --yes` drives the fixed
   pipeline (rebase → review → test → document → lint → push → pr → ci) with its own
   auto-fix loop, in no-mistakes' own worktree.
6. Dispatch on the parsed **outcome**:
   - `checks-passed` — CI green, PR open: ensure the PR has `Closes #n`, comment + drop
     the agent label, remove git-ralph's worktree. **Issue stays open; PR waits for a
     human to merge.**
   - `passed` — PR merged: close the issue, remove the worktree.
   - `failed`/`cancelled` (or a semi-mode `ask-user` gate): `axi abort`, label
     `needs-human`, comment where to look, keep the worktree.
7. When no actionable issues remain, print `<promise>COMPLETE</promise>` and stop.

## Configuration

All via environment variables (with defaults):

| Variable        | Default                              | Purpose                                            |
| --------------- | ------------------------------------ | -------------------------------------------------- |
| `REPO`          | `origin` remote of the CWD repo      | `owner/repo` the loop reads/writes                 |
| `BASE_BRANCH`   | `main`                               | Branch worktrees are cut from (set to your default)|
| `AGENT_LABEL`   | `ready-for-agent`                    | Only issues with this label are picked             |
| `HUMAN_LABEL`   | `needs-human`                        | Applied when a gate fails                          |
| `BLOCKED_LABEL` | `blocked`                            | Issues with this label are skipped                 |
| `WORKTREE_ROOT` | `../ralph-worktrees`                 | Where per-issue worktrees live (give each lane its own) |
| `ONLY_ISSUES`   | _(unset)_                            | Allowlist of issue numbers (`"12,15"`) — for parallel lanes |
| `NM_BIN`        | `no-mistakes`                        | The gate CLI on `PATH`                             |
| `NM_YES`        | `1`                                  | Autonomous (`axi run --yes`); empty = semi/HITL    |
| `AGENT`         | `claude`                             | `claude` or `codex` (the plan/implement agent)     |
| `AUTO_PLAN`     | `0`                                  | `1` = auto-approve the plan inline; `0` = semi (await human) |
| `PLAN_MODEL`    | `claude-opus-4-8`                    | Model for the Plan stage (strong reasoner)         |
| `CODE_MODEL`    | `claude-sonnet-4-6`                  | Model for Implement (cheaper/faster)               |
| `PROMPT_DIR`    | `<script dir>/prompts`               | Where `plan.md` / `build.md` live                  |
| `DRY_RUN`       | _(unset)_                            | If set, print the selection (and stage) and exit   |
| `MAX_ITER`      | `20` (or first positional arg)       | Max loop iterations                                |

### Plan stage & approval (semi vs `AUTO_PLAN`)

Before implementing, a `PLAN_MODEL` agent writes a short plan and the harness posts it to
the issue as an `<!-- ralph:plan -->` comment (the canonical, audit-stable record).

- **Semi mode** (default, `AUTO_PLAN=0`): the issue is parked on `awaiting-plan` and the
  loop moves on. A human reviews the plan comment and approves by **adding the
  `plan-approved` label** (no need to remove `awaiting-plan`). On a later pass the selector
  picks it up first and implements straight against the approved plan.
- **Full-auto** (`AUTO_PLAN=1`): the plan is posted then auto-approved, and the same
  iteration proceeds to implement. The only human touch-point left is reviewing/merging
  the gate's PR.

Per-stage models: Plan uses `PLAN_MODEL`, Implement uses `CODE_MODEL` (claude only; codex
ignores them). The gate's own stages (review/test/lint/…) run on no-mistakes' configured
agent — see `.no-mistakes.yaml`.

### The test command (`.no-mistakes.yaml`, not an env var)

The test command moved from `VALIDATE_CMD` into `.no-mistakes.yaml` under `commands.test`,
because the gate runs it. no-mistakes reads `commands.*`/`agent` from the **default branch
only** (so a pushed feature branch can't inject shell), so this file must be committed to
`main`. It runs **inside a fresh checkout** (no `node_modules`/`.venv`), so make it
self-contained:

```yaml
# .no-mistakes.yaml on main
agent: claude
commands:
  test: "npm install --silent && npm run typecheck && npm test"   # Node
  # test: "python -m pytest -q -m 'not integration and not smoke'" # Python
  # test: "go build ./... && go test ./..."                        # Go
auto_fix:
  review: 3      # the in-scope review->remediate loop that replaced GATE 2
```

### Running lanes in parallel

Running several sessions at once has **four** distinct contention sources. The first three
are fully fixable with isolation; the fourth is an integration-process problem the harness
can't solve alone.

| Source | Symptom | Fix |
|---|---|---|
| Same issue picked | Both lanes take the top issue → same branch → daemon cancels the in-flight run | `ONLY_ISSUES` per lane (disjoint numbers) |
| Shared worktree root | A lane's `safe_worktree_remove` wipes another's worktree | Per-lane `WORKTREE_ROOT` (or separate clone) |
| **Shared daemon** | One daemon per machine — any lane's `daemon stop` (or exit trap) kills **everyone's** in-flight gate runs | Per-lane **`NM_HOME`** → independent daemon/socket/db/gate |
| Base moves faster than the gate | Long gate (tests + review) on a **hot file** → base advances → PR re-conflicts forever | Not a harness problem — see below |

Fully-isolated lane recipe — use the **`scripts/run-lane.sh`** wrapper, which sets the
per-lane `NM_HOME` / `WORKTREE_ROOT` / `ONLY_ISSUES`, inits the lane's gate, runs the
harness, and **does not** stop the daemon (stopping mid-run orphans agents):

```bash
# Lane A (terminal/session 1) — run from its own clone of the target repo
cd /path/to/clone-a
bash /path/to/git-ralph/scripts/run-lane.sh a "12,13" 5

# Lane B (terminal/session 2) — a different clone + issue set
cd /path/to/clone-b
bash /path/to/git-ralph/scripts/run-lane.sh b "20,21" 5
```

`run-lane.sh a "12,13"` → `NM_HOME=~/.nm-lane-a`, `WORKTREE_ROOT=../ralph-wt-a`,
`ONLY_ISSUES="12,13"`. Stop a lane's daemon only when it is idle:
`NM_HOME=~/.nm-lane-a no-mistakes daemon stop`. The equivalent raw form, if you prefer:

```bash
export NM_HOME=~/.nm-lane-a
cd /path/to/clone-a && no-mistakes init
ONLY_ISSUES="12,13" WORKTREE_ROOT=../wt-lane-a bash /path/to/git-ralph/scripts/ralph/ralph-gh.sh 5
```

> ⚠️ **Do NOT append `; no-mistakes daemon stop` (or trap it on exit) when lanes run
> concurrently.** There is one daemon per `NM_HOME`; stopping it aborts every in-flight run
> that shares it. With per-lane `NM_HOME` each lane has its own daemon, so a stop is scoped:
> `NM_HOME=~/.nm-lane-a no-mistakes daemon stop`. Stop a shared daemon only when **all**
> lanes are done (that one-line stop is fine for a single idle session — see "PowerShell
> windows popping up" below).

**The fourth source (base velocity) is not fixable by `ONLY_ISSUES`.** Partitioning by issue
number doesn't help when the issues touch the **same hot file** — a ~30-min gate cycle can't
converge against a base that moves every few minutes on that file. Address it at the
integration layer:

- **Use a merge queue** (GitHub native merge queue or a bot) so PRs integrate serially
  against the tip and auto-rebase. This is the real fix for "base moves faster than the gate."
- **Partition lanes by file/module ownership, not just issue number.** Two issues that both
  touch a hot file are inherently serial — run them in one lane, sequentially, not in two.
- **Shrink the gate** so it cycles faster (a targeted `commands.test` subset, trading some
  safety for speed).
- **Long term, split the hot file** so parallel PRs stop colliding on it.

For an ad-hoc clean gate drive, pause the other lanes first.

## Key files

| File                              | Purpose                                                      |
| --------------------------------- | ----------------------------------------------------------- |
| `scripts/ralph/ralph-gh.sh`       | The loop: select → worktree → agent → commit → `axi run` → dispatch |
| `scripts/ralph/lib.sh`            | Pure, sourceable logic (the bats-testable "brain")          |
| `scripts/ralph/prompts/plan.md`   | Prompt for the Plan stage agent                             |
| `scripts/ralph/prompts/build.md`  | Prompt for the implementing agent                           |
| `.no-mistakes.yaml`               | Gate config (`commands.test`, `agent`, `auto_fix`) — on `main` |
| `scripts/ralph/tests/*.bats`      | The harness's own test suite (`npm test`)                   |
| `scripts/setup-labels.sh`         | Idempotently create the operational + triage labels         |
| `scripts/setup-no-mistakes.sh`    | Idempotently init the no-mistakes gate + daemon             |
| `scripts/run-lane.sh`             | Launch one isolated lane (NM_HOME/WORKTREE_ROOT/ONLY_ISSUES) for parallel runs |
| `scripts/setup-upstream.sh`       | Wire the `upstream` remote for syncing                      |
| `AGENTS.md` / `docs/agents/`      | Skill configuration (issue tracker, labels, domain docs)    |
| `CONTEXT.md`                      | Domain glossary the agents and skills speak in              |
| `SYNC.md`                         | How to pull updates from upstream without conflicts         |

### Pure logic in `lib.sh`

The decision logic is factored out of the I/O so it can be unit-tested without a
network or `gh`:

- `select_issue_from_json` — `plan-approved`-first, blocked/awaiting-plan exclusion,
  optional `ONLY_ISSUES` allowlist, priority sort → next issue number
- `issue_stage_from_labels` — `plan` vs `implement` from an issue's labels
- `model_flag` — per-stage `--model` flag for the agent runner (claude)
- `parse_axi_outcome` — fail-safe TOON parser → `checks-passed`/`passed`/`failed`/
  `cancelled`/`gate` (ambiguous → `failed`)
- `axi_dispatch` — outcome → harness action (`finalize-pr`/`close-issue`/`needs-human`)
- `gate_has_ask_user` — true when a semi-mode gate needs a human decision
- `parse_axi_pr_url` — pull the PR URL out of the run object to attach `Closes #n`
- `slugify` — branch-name slug from an issue title
- `repo_slug_from_url` — `owner/repo` from any remote URL

## The gate (no-mistakes)

git-ralph commits the agent's work and hands the branch to **no-mistakes** with a single
`axi run --intent "<issue goal>" --yes`. That one call drives a fixed, opinionated
pipeline — `intent → rebase → review → test → document → lint → push → pr → ci` — each
step with its own **auto-fix loop** (the in-scope review→remediate loop that replaced the
old GATE 2). The harness no longer parses a verdict or pushes/opens PRs itself; it reads
the terminal **outcome**:

- `checks-passed` — CI is green and the PR is open, waiting on a human to merge.
- `passed` — the PR was merged.
- `failed` / `cancelled` — escalate to a human.

Parsing is **fail-safe**: empty or unrecognized output → `failed` → `needs-human`, so the
harness never silently finalizes on ambiguous gate output. The gate reads `commands.test`
and `agent` from the **default branch** copy of `.no-mistakes.yaml`, not the pushed branch.

## Testing the harness

```bash
npm install      # installs bats (devDependency)
npm test         # runs bats over scripts/ralph/tests
```

## Critical concepts

### Each issue = fresh context

Every issue is handled by a new agent instance with clean context. Memory between runs
lives in git history, the issue/PR comments the agent leaves, and `CONTEXT.md`/`AGENTS.md`.

### Small issues (vertical slices)

Each issue should be a single vertical slice completable in one context window. Use
`/to-issues` to break a PRD into tracer-bullet slices. Too big ("build the dashboard",
"add auth") → split before running.

### Feedback loops are mandatory

The harness only works if `.no-mistakes.yaml`'s `commands.test` genuinely catches
breakage. No tests = no backpressure = compounding bad code. The gate also reviews,
lints, and watches CI, but the test command is the load-bearing signal.

### Memory updates

After a passing issue, let the agent update `CONTEXT.md`/`AGENTS.md` with discovered
patterns, gotchas, and conventions (via the `domain-modeling` skill). This replaces
`progress.txt`.

### Stop condition

When no `ready-for-agent` issues remain, the loop prints `<promise>COMPLETE</promise>`
and exits.

### Backlog hygiene (important)

The selector grabs **any** open `ready-for-agent` issue. Before a real run:

- **Remove `ready-for-agent` from the PRD parent** — it is an umbrella, not an
  implementable slice, or the loop will try to "implement" it.
- **Encode dependencies.** Sub-issues with an order (S1 → S2 → S3) should carry
  `blocked` (and/or priorities) so a later slice isn't grabbed before its blocker.
- **Pilot on exactly one issue.** To target a single issue without disturbing the real
  backlog, give it a temporary label and run with that as the agent label:
  ```bash
  gh issue edit <n> --add-label pilot
  AGENT_LABEL=pilot MAX_ITER=1 bash scripts/ralph/ralph-gh.sh 1
  ```

## Debugging

```bash
# What would the loop pick next?
DRY_RUN=1 bash scripts/ralph/ralph-gh.sh

# Issues ready for the agent
gh issue list --label ready-for-agent --state open

# A failed run keeps its worktree — inspect it
git worktree list
cd ../<worktree-root>/wt-<n> && git status && git diff

# Issues that stalled
gh issue list --label needs-human --state open
```

## Troubleshooting

- **Loop prints `COMPLETE` immediately even though issues are labelled.** `gh` may be
  resolving the wrong repo when several remotes exist (e.g. after adding `upstream`).
  `REPO` defaults to the `origin` remote URL to avoid this; pass `REPO=<owner/repo>`
  explicitly if needed. Also confirm `BASE_BRANCH` matches the repo's default branch
  (e.g. `dev`, not `main`).
- **The test step fails on a clean checkout.** The gate runs `commands.test` in a fresh
  worktree with no installed deps — make it install them (e.g.
  `npm install --silent && npm test`). See "The test command (`.no-mistakes.yaml`)".
- **The gate runs the wrong/empty test command.** no-mistakes reads `commands.test` from
  the **default branch** copy of `.no-mistakes.yaml`, never the pushed branch — commit
  your change to `main`. If the fetch fails it forces the command empty by design.
- **`COMPLETE` but the daemon never started.** `scripts/setup-no-mistakes.sh` must have
  run and `no-mistakes doctor` must pass; the loop calls `no-mistakes daemon start` but
  needs the binary on `PATH` (`NM_BIN`).
- **A run stalls as `needs-human`.** Inspect with `no-mistakes axi status` and
  `no-mistakes axi logs --step <step>`; the worktree is kept for you.
- **`bad interpreter` / `command not found` running a script on Windows.** CRLF line
  endings; `.gitattributes` pins `*.sh` to LF — re-check out, or fix your editor.
- <a name="powershell-windows-popping-up"></a>**Hundreds of empty console windows pile up
  and stay open (Windows).** These are **orphaned `claude.exe` agents** that no-mistakes
  spawns per pipeline step (review/test/document/fix). They orphan when the daemon is
  **killed mid-run** — and the usual killer is a `no-mistakes daemon stop` (a per-run suffix
  or an exit trap) firing while a run is still active. The daemon log shows it as repeated
  `method=shutdown` + `cancelled run on shutdown`. Fixes, in order:
  1. **Never `daemon stop` while a run is active.** Stop it only when the machine is truly
     idle (no in-flight gate run). Remove any `; no-mistakes daemon stop` suffix / exit trap
     from your run wrapper.
  2. **Per-lane `NM_HOME`** when running concurrent sessions, so each has its own daemon and
     a stop in one lane can't orphan another's agents (see "Running lanes in parallel").
  3. Clean up existing orphans (kills only `claude` whose parent has died — leaves your
     live Claude Code sessions, whose parent `Code.exe`/`node` is alive):
     ```powershell
     Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
       Where-Object { -not (Get-Process -Id $_.ParentProcessId -ErrorAction SilentlyContinue) } |
       ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
     ```
  The idle daemon also *flashes* (not piles up) windows on a timer; that one stops cleanly
  with `no-mistakes daemon stop` when no run is active (it does not auto-start on boot).

## Staying current with upstream

This is a fork-style project layered on `snarktank/ralph` and `mattpocock/skills`.
See [SYNC.md](./SYNC.md): add the `upstream` remote (`scripts/setup-upstream.sh`),
then `git fetch upstream && git merge upstream/main && npm test`. Because we only add
files and never edit upstream's, merges stay (near) conflict-free.

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [snarktank/ralph](https://github.com/snarktank/ralph) — the upstream this forks
- [mattpocock/skills](https://github.com/mattpocock/skills) — the engineering skills
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code)
