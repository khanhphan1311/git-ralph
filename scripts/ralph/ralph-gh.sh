#!/usr/bin/env bash
# ralph-gh.sh — GitHub-issue/PR-driven Ralph loop + mattpocock skills.
#
# git-ralph owns: select issue -> worktree -> implement (TDD) -> commit.
# no-mistakes owns the gate: a single `axi run` drives rebase -> review -> test ->
# document -> lint -> push -> pr -> ci (with its own auto-fix loop) and stops at a
# terminal outcome. git-ralph reads that outcome and labels/comments/cleans up; it
# never merges. See https://github.com/kunchenguid/no-mistakes (#23).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

# ---------- Config (override via env) ----------
# Pin REPO to the `origin` remote — `gh repo view` guesses wrong when an `upstream`
# remote (snarktank/ralph) also exists (#14). Fall back to gh only if origin is absent.
REPO="${REPO:-$(repo_slug_from_url "$(git remote get-url origin 2>/dev/null)" 2>/dev/null)}"
REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
BASE_BRANCH="${BASE_BRANCH:-main}"
AGENT_LABEL="${AGENT_LABEL:-ready-for-agent}"
HUMAN_LABEL="${HUMAN_LABEL:-needs-human}"
BLOCKED_LABEL="${BLOCKED_LABEL:-blocked}"
WORKTREE_ROOT="${WORKTREE_ROOT:-../ralph-worktrees}"
AGENT="${AGENT:-claude}"
PROMPT_DIR="${PROMPT_DIR:-${HERE}/prompts}"
# no-mistakes is the gate. NM_BIN is the CLI; NM_YES=1 (default) runs the autonomous
# path (`axi run --yes`, auto-resolve every gate). Empty NM_YES selects the semi/HITL
# path: a gate pauses the harness and escalates to a human instead of auto-resolving.
NM_BIN="${NM_BIN:-no-mistakes}"
NM_YES="${NM_YES:-1}"
DRY_RUN="${DRY_RUN:-}"
MAX_ITER="${1:-20}"

log() { printf '\033[1;34m[ralph]\033[0m %s\n' "$*"; }

# agent_run <prompt-file> — run the configured agent with the prompt's contents.
agent_run() {
  case "$AGENT" in
    claude) claude -p --dangerously-skip-permissions "$(cat "$1")" ;;
    codex)  codex exec --yolo - < "$1" ;;
    *) echo "Unsupported AGENT: $AGENT" >&2; return 2 ;;
  esac
}

# ensure_daemon — best-effort: confirm the no-mistakes CLI is present and the gate
# daemon is up before the loop starts (AC 1). `daemon start` is idempotent and
# refreshes a stale managed service, so it is safe to call every run.
ensure_daemon() {
  if ! command -v "$NM_BIN" >/dev/null 2>&1; then
    log "no-mistakes ($NM_BIN) not on PATH — run scripts/setup-no-mistakes.sh first."
    return 1
  fi
  "$NM_BIN" daemon start >/dev/null 2>&1 || true
}

# select_next_issue — highest-priority open ready-for-agent issue, not blocked.
select_next_issue() {
  gh issue list --repo "$REPO" --state open --label "$AGENT_LABEL" \
    --json number,labels --limit 200 \
    | select_issue_from_json "$BLOCKED_LABEL"
}

# build_intent <num> — the user's GOAL for no-mistakes' review, not a diff summary.
# Issue body + comments carry the decisions/tradeoffs (including the harness's own
# [Kickoff]/[Decision] notes), which is exactly what review uses to tell deliberate
# choices apart from mistakes.
build_intent() {
  local num="$1"
  printf 'Resolve GitHub issue #%s. The goal, decisions, and tradeoffs follow.\n\n' "$num"
  gh issue view "$num" --repo "$REPO" --comments
}

# run_axi <worktree> <intent> — drive the no-mistakes gate for the committed branch in
# <worktree>, blocking until a terminal outcome (or, in semi mode, the first gate).
# stdout (TOON) is captured for the parser; stderr (progress) flows to the terminal.
run_axi() {
  local wt="$1" intent="$2"
  if [ -n "$NM_YES" ]; then
    ( cd "$wt" && "$NM_BIN" axi run --intent "$intent" --yes )
  else
    ( cd "$wt" && "$NM_BIN" axi run --intent "$intent" )
  fi
}

# run_once — process exactly one issue. Returns 10 when the backlog is empty.
run_once() {
  local num title slug branch wt build_prompt issue_ctx agent_rc
  local intent axi_out outcome action pr_url

  num="$(select_next_issue || true)"
  if [ -z "${num:-}" ]; then
    log "No '$AGENT_LABEL' issues left. <promise>COMPLETE</promise>"
    return 10
  fi
  log "Selected issue #$num"

  title="$(gh issue view "$num" --repo "$REPO" --json title -q .title)"
  slug="$(slugify "$title")"
  branch="agent/${num}-${slug}"
  wt="${WORKTREE_ROOT}/wt-${num}"

  git fetch origin "$BASE_BRANCH" --quiet
  if [ -d "$wt" ]; then
    log "Resume worktree $wt"
  else
    mkdir -p "$WORKTREE_ROOT"
    git worktree add -B "$branch" "$wt" "origin/${BASE_BRANCH}"
  fi

  issue_ctx="$(gh issue view "$num" --repo "$REPO" --comments)"
  build_prompt="$(mktemp)"
  { prepend_rules "${PROMPT_DIR}/rules.md"; cat "${PROMPT_DIR}/build.md"; echo; echo "## GitHub issue #$num"; echo "$issue_ctx"; } > "$build_prompt"

  set +e; ( cd "$wt" && agent_run "$build_prompt" ); agent_rc=$?; set -e
  if [ "$agent_rc" -ne 0 ]; then
    log "FAIL #$num (agent rc=$agent_rc) -> needs-human"
    mark_needs_human "$num" "$branch" "$wt" "agent rc=$agent_rc"
    return 0
  fi

  # Commit the agent's work — `axi run` refuses an uncommitted tree, and a branch with
  # no diff against the base has nothing to gate.
  ( cd "$wt"; git add -A; git commit -m "feat: resolve #$num — $title" >/dev/null 2>&1 || true )
  if ( cd "$wt" && git diff --quiet "origin/${BASE_BRANCH}" ); then
    log "FAIL #$num (agent produced no changes) -> needs-human"
    mark_needs_human "$num" "$branch" "$wt" "no diff against origin/${BASE_BRANCH}"
    return 0
  fi

  # The gate: one headless `axi run` replaces GATE 1 (validate) + GATE 2 (review) +
  # push + PR. no-mistakes runs its fixed pipeline with its own auto-fix loop.
  log "GATE: no-mistakes axi run (#$num, yes=${NM_YES:-0})"
  intent="$(build_intent "$num")"
  set +e; axi_out="$(run_axi "$wt" "$intent")"; set -e

  outcome="$(parse_axi_outcome <<<"$axi_out")"
  if [ "$outcome" = "gate" ] && [ -z "$NM_YES" ]; then
    # Semi/HITL path: a human owns the gate. Relay the findings and escalate.
    log "GATE paused (#$num) -> needs-human (semi mode)"
    mark_needs_human "$num" "$branch" "$wt" "gate awaiting approval (semi mode)"
    return 0
  fi

  action="$(axi_dispatch "$outcome")"
  log "outcome=$outcome -> $action (#$num)"
  case "$action" in
    finalize-pr)
      pr_url="$(parse_axi_pr_url <<<"$axi_out")"
      finalize_pr "$num" "$pr_url" "$branch" "$wt" ;;
    close-issue)
      close_issue_done "$num" "$branch" "$wt" ;;
    *)
      mark_needs_human "$num" "$branch" "$wt" "axi outcome=$outcome" ;;
  esac
}

# finalize_pr — success path for `checks-passed`: CI is green and the PR is open,
# waiting on a human to merge. Make sure the PR body carries `Closes #n` (no-mistakes
# may not have included it), comment the issue with the PR link, drop the agent label,
# and remove git-ralph's own worktree. The issue stays OPEN — GitHub closes it when the
# human merges. git-ralph never merges (kept Out-of-Scope from #1).
finalize_pr() {
  local num="$1" pr_url="$2" branch="$3" wt="$4" body
  if [ -n "$pr_url" ]; then
    body="$(gh pr view "$pr_url" --repo "$REPO" --json body -q .body 2>/dev/null || true)"
    case "$body" in
      *"Closes #$num"*|*"closes #$num"*) : ;;
      *) gh pr edit "$pr_url" --repo "$REPO" \
           --body "$(printf '%s\n\nCloses #%s' "$body" "$num")" >/dev/null 2>&1 || true ;;
    esac
    gh issue comment "$num" --repo "$REPO" \
      --body "no-mistakes gate passed — CI green. PR ready for human review/merge: $pr_url"
  else
    gh issue comment "$num" --repo "$REPO" \
      --body "no-mistakes gate passed — CI green. PR ready for human review/merge."
  fi
  gh issue edit "$num" --repo "$REPO" --remove-label "$AGENT_LABEL" >/dev/null 2>&1 || true
  safe_worktree_remove "$wt"
}

# close_issue_done — terminal `passed`: the PR was merged/closed. Close the issue (in
# case no `Closes #n` auto-closed it), drop the agent label, and clean up the worktree.
close_issue_done() {
  local num="$1" branch="$2" wt="$3"
  gh issue comment "$num" --repo "$REPO" \
    --body "no-mistakes pipeline passed and the PR merged. Done by ralph-gh (branch \`$branch\`)."
  gh issue edit "$num" --repo "$REPO" --remove-label "$AGENT_LABEL" >/dev/null 2>&1 || true
  gh issue close "$num" --repo "$REPO" 2>/dev/null || true
  safe_worktree_remove "$wt"
}

# mark_needs_human — failure/escalation path. Reap any orphaned gate run for the branch
# (`axi abort` is a no-op when none is active), flag the issue for a human, log where to
# look, and KEEP the worktree for inspection. Does not push, PR, merge, or close.
mark_needs_human() {
  local num="$1" branch="$2" wt="$3" reason="$4"
  [ -d "$wt" ] && ( cd "$wt" && "$NM_BIN" axi abort >/dev/null 2>&1 || true )
  gh issue edit "$num" --repo "$REPO" \
    --add-label "$HUMAN_LABEL" --remove-label "$AGENT_LABEL" >/dev/null 2>&1 || true
  gh issue comment "$num" --repo "$REPO" \
    --body "ralph-gh stopped ($reason). Inspect branch \`$branch\` / worktree \`$wt\`; see \`no-mistakes axi status\` and \`no-mistakes axi logs --step <step>\`."
}

# safe_worktree_remove <worktree-path>
# Unlink any junctions/symlinks inside the worktree BEFORE git removes it, so
# `git worktree remove --force` can't follow a reparse point and delete the real
# target data (#19). On Windows, NTFS junctions need PowerShell to detect reliably.
safe_worktree_remove() {
  local wt="$1" link
  if [ -d "$wt" ]; then
    if is_windows; then
      powershell.exe -NoProfile -ExecutionPolicy Bypass \
        -File "$(cygpath -w "${HERE}/safe-worktree-remove.ps1")" \
        -WorktreePath "$(cygpath -w "$wt")" || true
    else
      while IFS= read -r link; do
        [ -n "$link" ] && unlink "$link"
      done < <(find "$wt" -type l 2>/dev/null)
    fi
  fi
  git worktree remove "$wt" --force
}

# dry_run — print what the selector would pick next, touching nothing (no worktree,
# no agent, no labels). Read-only: useful to sanity-check priority/blocked logic.
dry_run() {
  local num title
  num="$(select_next_issue || true)"
  if [ -z "${num:-}" ]; then
    log "DRY-RUN: no '$AGENT_LABEL' issues -> would print <promise>COMPLETE</promise>"
  else
    title="$(gh issue view "$num" --repo "$REPO" --json title -q .title)"
    log "DRY-RUN: would select #$num — $title"
  fi
}

main() {
  ensure_daemon || { log "Gate unavailable — aborting loop."; return 1; }
  local iter=0
  while (( iter < MAX_ITER )); do
    iter=$((iter + 1)); log "iteration $iter/$MAX_ITER"
    run_once || { [ "$?" -eq 10 ] && break || true; }
  done
}

# Only run when executed directly — sourcing (e.g. from bats) must not.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ -n "$DRY_RUN" ]; then dry_run; else main; fi
fi
