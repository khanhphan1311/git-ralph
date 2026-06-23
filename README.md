# git-ralph

GitHub-issue/PR-driven Ralph loop + mattpocock engineering skills. The harness pulls
the highest-priority `ready-for-agent` issue, isolates it in a git worktree, has an
agent implement a single vertical slice, gates the result behind validation +
independent review, and opens a draft PR.

Full design: [`ralph-gh-plan.md`](./ralph-gh-plan.md). Skill config: [`docs/agents/`](./docs/agents).

## Prerequisites

| Tool        | Why                              | Check                              |
| ----------- | -------------------------------- | ---------------------------------- |
| `gh` (auth) | Issues, PRs, labels              | `gh auth status` (scope: `repo`)   |
| `git` ≥2.30 | `git worktree` per-issue isolation | `git --version`                  |
| `jq`        | Issue-selection priority logic   | `jq --version`                     |
| `claude`    | Default agent backend            | `claude --version`                 |
| `bats`      | Harness's own test suite (dev)   | `npx bats --version`               |
| `codex`     | Optional alt backend (`AGENT=codex`) | `codex --version`              |

`bats` is a dev dependency — `npm install` then `npm test`.

## Quick start

```bash
npm install                      # installs bats for the test suite
gh auth status                   # confirm logged in with repo scope
scripts/setup-labels.sh          # idempotently create the operational labels
# ... generate a backlog with /to-prd + /to-issues ...
MAX_ITER=1 VALIDATE_CMD="<your test cmd>" scripts/ralph/ralph-gh.sh 1   # one issue, one pass
```

## Configuration (env vars)

`REPO`, `BASE_BRANCH` (default `main`), `AGENT_LABEL`, `HUMAN_LABEL`, `BLOCKED_LABEL`,
`WORKTREE_ROOT`, `VALIDATE_CMD`, `AGENT` (`claude`|`codex`), `PROMPT_DIR`, `MAX_ITER`.

## Tests

```bash
npm test            # runs bats over scripts/ralph/tests
```

## Staying current with upstream

This is a fork-style project layered on `snarktank/ralph`. See [`SYNC.md`](./SYNC.md)
(added in the upstream-sync slice) for how to pull updates without conflicts.
