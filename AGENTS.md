# git-ralph

A GitHub-issue/PR-driven Ralph loop. An autonomous harness that pulls tasks from
GitHub Issues, isolates each in a git worktree/branch, implements them with an
agent (Claude Code / Codex) guided by engineering skills, gates the result behind
validation + independent review, and opens a draft Pull Request.

See `ralph-gh-plan.md` for the full design and `docs/agents/` for skill configuration.

## Agent skills

### Issue tracker

Issues and PRDs live as GitHub issues on `khanhphan1311/git-ralph`, driven via the
`gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical triage roles map 1:1 to label strings; this harness also adds the
operational labels `ready-for-agent`, `needs-human`, `blocked`, `awaiting-plan`,
`plan-approved`, and priorities `P0`/`P1`/`P2`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context repo: `CONTEXT.md` + `docs/adr/` at the root. See `docs/agents/domain.md`.

## Base branch

`main` is the integration branch. There is no `dev` branch — agents fork feature
branches (`agent/<n>-<slug>`) from `origin/main`.
