# git-ralph

An autonomous AI agent loop that pulls tasks from **GitHub Issues**, isolates each
one in a **git worktree/branch**, has an AI coding tool implement a single vertical
slice, gates the result behind **validation + independent review**, and opens a
**draft Pull Request**. Each issue is handled in a fresh agent context; memory
persists via git history, issue/PR comments, and `CONTEXT.md`/`AGENTS.md`.

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
| Commit on a story                 | commit → push → **draft PR** → close issue                |
| Typecheck/test gate               | **GATE 1 validation + GATE 2 independent review**         |

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
           GATE 1: validate (VALIDATE_CMD: typecheck + tests)     ← backpressure
           GATE 2: independent review (separate context, verdict) ← fail-safe
                  │
        PASS → commit → push → gh pr create --draft → gh issue close → remove worktree
        FAIL → label needs-human → comment rc codes → keep worktree for a human
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
| `bats`       | The harness's own test suite (dev)   | `npx bats --version`             |
| `codex`      | Optional alt backend (`AGENT=codex`) | `codex --version`                |

You also need a **target git repository** with a remote `origin` on GitHub and
permission to create labels, issues, and PRs on it.

## Setup

### Option 1 — Point the harness at any repo (no vendoring)

All `git`/`gh` operations run against the **current working directory**, and prompts
are read from the harness's own folder. So you can run the harness against any repo by
invoking the script from inside that repo's clone and overriding a few env vars:

```bash
cd /path/to/your/target/repo

BASE_BRANCH=main \                                  # your repo's default branch
WORKTREE_ROOT=../your-repo-worktrees \              # where per-issue worktrees go
VALIDATE_CMD='<your typecheck + test command>' \    # see "Configuration"
MAX_ITER=1 \
bash /path/to/git-ralph/scripts/ralph/ralph-gh.sh 1
```

`REPO` auto-resolves from the target's `origin` remote. Use this for quick runs.

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

Then customise `scripts/ralph/prompts/{build,review}.md` for your stack.

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
MAX_ITER=1 VALIDATE_CMD='<your test cmd>' bash scripts/ralph/ralph-gh.sh 1

# Drain the backlog (up to N iterations)
VALIDATE_CMD='<your test cmd>' bash scripts/ralph/ralph-gh.sh 20
```

### 3. What happens each iteration

1. Select the highest-priority open `ready-for-agent` issue that is not `blocked`
   (`P0 < P1 < P2 < unlabelled`, ties broken by issue number).
2. Create — or resume — a worktree + branch `agent/<n>-<slug>` from `origin/BASE_BRANCH`.
3. Run the agent with `prompts/build.md` + the issue body & comments.
4. **GATE 1** — run `VALIDATE_CMD` in the worktree.
5. **GATE 2** — run an independent reviewer agent on the diff; parse its verdict.
6. **PASS** (agent ok + GATE 1 + GATE 2): commit → push → open a draft PR (`Closes #n`)
   → comment + close the issue → remove the worktree.
   **FAIL**: label the issue `needs-human`, comment the gate codes, keep the worktree.
7. When no `ready-for-agent` issues remain, print `<promise>COMPLETE</promise>` and stop.

## Configuration

All via environment variables (with defaults):

| Variable        | Default                              | Purpose                                            |
| --------------- | ------------------------------------ | -------------------------------------------------- |
| `REPO`          | `origin` remote of the CWD repo      | `owner/repo` the loop reads/writes                 |
| `BASE_BRANCH`   | `main`                               | Branch worktrees are cut from (set to your default)|
| `AGENT_LABEL`   | `ready-for-agent`                    | Only issues with this label are picked             |
| `HUMAN_LABEL`   | `needs-human`                        | Applied when a gate fails                          |
| `BLOCKED_LABEL` | `blocked`                            | Issues with this label are skipped                 |
| `WORKTREE_ROOT` | `../ralph-worktrees`                 | Where per-issue worktrees live                     |
| `VALIDATE_CMD`  | `npm run typecheck && npm test`      | GATE 1; **set this to your stack** (see below)     |
| `AGENT`         | `claude`                             | `claude` or `codex`                                |
| `PROMPT_DIR`    | `<script dir>/prompts`               | Where `build.md` / `review.md` live                |
| `DRY_RUN`       | _(unset)_                            | If set, print the selection and exit               |
| `MAX_ITER`      | `20` (or first positional arg)       | Max loop iterations                                |

### Choosing `VALIDATE_CMD`

This is the single most important setting — it is the feedback loop that stops broken
code from being finalized. It runs **inside a fresh worktree checkout**, so it must be
self-contained. Examples:

```bash
# Node                                                                        
VALIDATE_CMD='npm install --silent && npm run typecheck && npm test'

# Python (skip tests needing infra; ensure deps are importable)
VALIDATE_CMD='python -m pytest -q -m "not integration and not smoke"'

# Go
VALIDATE_CMD='go build ./... && go test ./...'
```

> ⚠️ **The worktree is a clean checkout** — it has no `node_modules`, no `.venv`, no
> build artifacts. Either make `VALIDATE_CMD` install/prepare what it needs, or run the
> harness from a shell where the toolchain (active virtualenv, installed deps) is
> already on `PATH`. For Python in particular, an editable install (`pip install -e`)
> resolves imports to the *original* repo path, not the worktree — prefer
> `python -m pytest` run from the worktree so the worktree's code is on `sys.path`.

## Key files

| File                              | Purpose                                                      |
| --------------------------------- | ----------------------------------------------------------- |
| `scripts/ralph/ralph-gh.sh`       | The loop: select → worktree → agent → gates → finalize      |
| `scripts/ralph/lib.sh`            | Pure, sourceable logic (the bats-testable "brain")          |
| `scripts/ralph/prompts/build.md`  | Prompt for the implementing agent                           |
| `scripts/ralph/prompts/review.md` | Prompt for the independent reviewer                         |
| `scripts/ralph/tests/*.bats`      | The harness's own test suite (`npm test`)                   |
| `scripts/setup-labels.sh`         | Idempotently create the operational + triage labels         |
| `scripts/setup-upstream.sh`       | Wire the `upstream` remote for syncing                      |
| `AGENTS.md` / `docs/agents/`      | Skill configuration (issue tracker, labels, domain docs)    |
| `CONTEXT.md`                      | Domain glossary the agents and skills speak in              |
| `SYNC.md`                         | How to pull updates from upstream without conflicts         |

### Pure logic in `lib.sh`

The decision logic is factored out of the I/O so it can be unit-tested without a
network or `gh`:

- `select_issue_from_json` — priority/blocked sort → next issue number
- `parse_review_verdict` — fail-safe verdict parsing (only an exact first-line
  `REVIEW: PASS` passes)
- `gate_outcome` — `finalize` only when agent + GATE 1 + GATE 2 all pass
- `slugify` — branch-name slug from an issue title
- `repo_slug_from_url` — `owner/repo` from any remote URL

## The two gates

- **GATE 1 — validation.** Runs `VALIDATE_CMD` in the worktree. Typecheck + tests are
  the backpressure that keeps the backlog from compounding broken code.
- **GATE 2 — independent review.** A *separate* agent context reviews the diff against
  the issue and must emit `REVIEW: PASS` or `REVIEW: FAIL` on its **first line**.
  Parsing is **fail-safe**: anything ambiguous is treated as `FAIL`, so code is never
  merged on an unclear verdict. Finalize requires *all three* (agent rc, GATE 1, GATE 2).

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

The harness only works if `VALIDATE_CMD` genuinely catches breakage. No typecheck/tests
= no backpressure = compounding bad code.

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
  AGENT_LABEL=pilot MAX_ITER=1 VALIDATE_CMD='<...>' bash scripts/ralph/ralph-gh.sh 1
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
- **GATE 1 always fails on a clean worktree.** The worktree has no installed deps — make
  `VALIDATE_CMD` install them, or activate the toolchain first (see "Choosing VALIDATE_CMD").
- **A genuine PASS is reported as `needs-human`.** The reviewer must put `REVIEW: PASS`
  on its very first line with nothing before it; verdict parsing is intentionally
  fail-safe. Tighten `prompts/review.md` if a backend rambles before the verdict.
- **`bad interpreter` / `command not found` running a script on Windows.** CRLF line
  endings; `.gitattributes` pins `*.sh` to LF — re-check out, or fix your editor.

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
