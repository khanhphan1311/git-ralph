# git-ralph

A GitHub-issue/PR-driven Ralph loop. An autonomous harness that pulls tasks from
GitHub Issues, isolates each in a git worktree/branch, implements them with an
agent (Claude Code / Codex) guided by engineering skills, then hands the branch to
the [no-mistakes](https://github.com/kunchenguid/no-mistakes) gate — one `axi run`
drives review → test → document → lint → push → pr → ci with its own auto-fix loop —
and stops at an outcome, leaving the open PR for a human to merge.

See `ralph-gh-plan.md` for the full design and `docs/agents/` for skill configuration.

## Agent skills

### Issue tracker

Issues and PRDs live as GitHub issues on `khanhphan1311/git-ralph`, driven via the
`gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical triage roles map 1:1 to label strings; this harness also adds the
operational labels `ready-for-agent`, `needs-human`, `blocked`, and priorities
`P0`/`P1`/`P2`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context repo: `CONTEXT.md` + `docs/adr/` at the root. See `docs/agents/domain.md`.

## Base branch

`main` is the integration branch. There is no `dev` branch — agents fork feature
branches (`agent/<n>-<slug>`) from `origin/main`.
