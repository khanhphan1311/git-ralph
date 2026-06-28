#!/usr/bin/env bash
# run-lane.sh — launch ONE isolated git-ralph lane for safe parallel runs.
#
# Each lane gets its own no-mistakes daemon (NM_HOME), its own worktree root, and a
# disjoint issue allowlist (ONLY_ISSUES) — the three things that stop concurrent lanes
# from cancelling each other's gate runs and deleting each other's worktrees. It
# deliberately does NOT stop the daemon afterward: a `daemon stop` while a run is still
# in flight orphans the per-step `claude` agents no-mistakes spawned, which on Windows
# pile up as empty console windows (#35). Stop a lane's daemon only when it is idle:
#   NM_HOME=~/.nm-lane-<name> no-mistakes daemon stop
#
# Usage:
#   run-lane.sh <lane-name> <issues> [max-iter]
#     <lane-name>  unique per lane (a, b, frontend, …); keys NM_HOME + worktree root
#     <issues>     comma/space allowlist, e.g. "101,102"
#     [max-iter]   loop iterations for this lane (default 5)
#
# Run it from inside the lane's target-repo clone (or set REPO_DIR). For full isolation,
# give each lane its OWN clone of the target repo — a shared .git races on `git worktree`.
#
# Env overrides:
#   REPO_DIR    target-repo clone to operate on (default: current directory)
#   NM_HOME     gate home for this lane (default: ~/.nm-lane-<name>)
#   WORKTREE_ROOT  where this lane's worktrees go (default: ../ralph-wt-<name>)
#   DRY_RUN     if set, only print the selection (and stage) — touches nothing
# Other harness env (AGENT, AUTO_PLAN, PLAN_MODEL, CODE_MODEL, …) passes through.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: run-lane.sh <lane-name> <issues> [max-iter]" >&2; exit 2; }
lane="${1:-}"; [ -n "$lane" ] || usage
issues="${2:-}"; [ -n "$issues" ] || usage
iters="${3:-5}"

export NM_HOME="${NM_HOME:-$HOME/.nm-lane-$lane}"
export ONLY_ISSUES="$issues"
export WORKTREE_ROOT="${WORKTREE_ROOT:-../ralph-wt-$lane}"

repo_dir="${REPO_DIR:-$PWD}"
ralph_sh="${HERE}/ralph/ralph-gh.sh"
[ -f "$ralph_sh" ] || { echo "ralph-gh.sh not found at $ralph_sh" >&2; exit 1; }

if ! command -v no-mistakes >/dev/null 2>&1; then
  echo "no-mistakes not on PATH (install + run scripts/setup-no-mistakes.sh)" >&2
  exit 1
fi

printf '[lane %s] NM_HOME=%s ONLY_ISSUES=%s WORKTREE_ROOT=%s repo=%s\n' \
  "$lane" "$NM_HOME" "$issues" "$WORKTREE_ROOT" "$repo_dir"

cd "$repo_dir"

# ralph-gh.sh defaults BASE_BRANCH=main; on a repo whose default branch is dev/master that
# makes `git worktree add ... origin/main` fail ("couldn't find remote ref main") and the
# lane dies before it starts. Auto-detect the repo's default branch when BASE_BRANCH is
# unset (local, no network — reads origin/HEAD).
if [ -z "${BASE_BRANCH:-}" ]; then
  BASE_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  export BASE_BRANCH="${BASE_BRANCH:-main}"
  printf '[lane %s] BASE_BRANCH auto-detected: %s\n' "$lane" "$BASE_BRANCH"
fi

# Ensure this lane's gate exists under its own NM_HOME (idempotent; refreshes if present).
no-mistakes init >/dev/null 2>&1 || true

# Run the harness. Its ensure_daemon starts THIS lane's daemon (scoped by NM_HOME).
# No `daemon stop` here on purpose — see the header note.
bash "$ralph_sh" "$iters"

printf '[lane %s] done. Daemon left running under %s.\n' "$lane" "$NM_HOME"
printf '[lane %s] stop it ONLY when idle:  NM_HOME=%s no-mistakes daemon stop\n' "$lane" "$NM_HOME"
