# Staying current with upstream

This project is layered on two upstreams. The whole design keeps them easy to
follow **because we only ADD files — we never edit or delete upstream files.**

| Upstream            | What we take from it                  | Our layer                          |
| ------------------- | ------------------------------------- | ---------------------------------- |
| `snarktank/ralph`   | The loop idea, prompts, flowchart     | `scripts/ralph/` (all new files)   |
| `mattpocock/skills` | Engineering skills (tdd, triage, …)   | `.claude/skills/` (vendored)       |

## The one rule

**Add files; don't modify or delete upstream's.** The original plan suggested
deleting `prd.json` / `progress.txt` / `skills/prd` / `skills/ralph`. We don't.
Deleting an upstream file turns every future merge into a recurring modify/delete
conflict. Our harness lives entirely in new files (`scripts/ralph/ralph-gh.sh`,
`lib.sh`, `prompts/`), so merges stay (near) conflict-free. If you ever need to
neutralise an upstream file, prefer ignoring it over deleting it.

## One-time setup

```bash
scripts/setup-upstream.sh        # adds the `upstream` remote idempotently
```

Or manually:

```bash
git remote add upstream https://github.com/snarktank/ralph
git fetch upstream
```

## Pulling updates (recommended: merge)

```bash
git fetch upstream
git checkout main
git merge upstream/main          # review the diff; do NOT blind auto-merge
npm test                         # our bats suite must stay green
```

Because `ralph-gh.sh` uses our own `prompts/build.md` + `review.md` (not snarktank's
prompts), upstream prompt/flowchart changes rarely affect runtime behaviour — but
still read the diff before merging into a branch you run for real.

### Alternative: vendor as a subtree

If you prefer a hard boundary between "ours" and "theirs":

```bash
git subtree add  --prefix vendor/ralph https://github.com/snarktank/ralph main --squash
git subtree pull --prefix vendor/ralph https://github.com/snarktank/ralph main --squash
```

## Tracking `mattpocock/skills`

The engineering skills live under `.claude/skills/`. Track them the same way —
either a second `upstream-skills` remote you merge from, or a `git subtree` under
`.claude/skills/`. Pin to a release tag and bump deliberately rather than tracking
`main`, so a skill change can't silently alter agent behaviour mid-run.

## Knowing when there's something to pull

Manual: on GitHub, **Watch → Custom → Releases** for both
`snarktank/ralph` and `mattpocock/skills`.

Scripted check:

```bash
gh release view --repo snarktank/ralph   --json tagName,publishedAt
gh release view --repo mattpocock/skills --json tagName,publishedAt
```

## Future automation (sketch, not yet built)

A scheduled job (GitHub Action cron, or `/schedule`) can compare the latest
upstream release tag against the one we last integrated and, when they differ,
open a `ready-for-agent` issue describing the upstream diff. The harness then picks
that issue up and ports the relevant changes through the same gates as any task —
the loop maintaining itself. Out of scope for now; tracked as a note here.
