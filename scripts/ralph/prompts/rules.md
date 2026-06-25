# Global engineering rules

These rules apply to every task. They are prepended to every harness prompt so that
every spawned agent receives them, regardless of backend (Claude Code / Codex) or host
configuration. Always follow them.

## Voice
- Never use the em dash. Use a plain dash (-).
- No filler, no marketing tone. Plain, direct language.

## Technical decisions
- When making technical decisions, do not give much weight to development cost.
  Prefer the best long-term architecture; implementation is cheap for an agent.

## Bug fixing
- Always start by reproducing the bug in an E2E setting before changing code.
- No shallow unit tests that only assert the happy path.
