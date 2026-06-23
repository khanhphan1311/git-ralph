# Domain Docs

How the engineering skills should consume this repo's domain documentation.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in.

If any of these files don't exist, **proceed silently**. The producer skill
(`/grill-with-docs`) creates them lazily when terms or decisions actually get resolved.

## File structure

Single-context repo:

```
/
├── CONTEXT.md
├── docs/adr/
└── scripts/ralph/
```

## Use the glossary's vocabulary

When your output names a domain concept (issue title, refactor proposal, hypothesis,
test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the
glossary explicitly avoids.

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than
silently overriding.
