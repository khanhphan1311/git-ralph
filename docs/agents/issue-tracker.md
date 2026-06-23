# Issue tracker: GitHub

Issues and PRDs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body-file <file>`. Use a file for multi-line bodies (preserves markdown).
- **Read an issue**: `gh issue view <number> --comments`, fetching labels via `--json labels`.
- **List issues**: `gh issue list --state open --json number,title,body,labels` with `--label` / `--state` filters.
- **Comment on an issue**: `gh issue comment <number> --body-file <file>`
- **Apply / remove labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`

The repo is inferred from `git remote -v` — `gh` does this automatically inside a clone.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.
