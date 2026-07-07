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
# Claimed-at-selection marker. On pick, an issue is dropped from AGENT_LABEL and stamped
# IN_PROGRESS so a concurrent session (even on another machine) won't re-pick it during the
# minutes-long run. Cleared on every terminal/park outcome; a hard-killed worker leaves it
# set on purpose (surfaces a stuck issue — remove the label to requeue).
IN_PROGRESS_LABEL="${IN_PROGRESS_LABEL:-in-progress}"
# Plan-stage labels (#21 Delta A). `awaiting-plan` parks an issue waiting for a human to
# vet its plan (skipped by the selector like `blocked`); `plan-approved` marks a vetted
# plan so the loop resumes it ahead of fresh work and jumps straight to implement.
AWAITING_PLAN_LABEL="${AWAITING_PLAN_LABEL:-awaiting-plan}"
PLAN_APPROVED_LABEL="${PLAN_APPROVED_LABEL:-plan-approved}"
# Parallel lanes: restrict this run to a comma/space-separated allowlist of issue numbers.
# Empty = the whole backlog. With the IN_PROGRESS claim above, sessions no longer NEED
# disjoint allowlists (the claim dedupes the backlog — they work-steal); ONLY_ISSUES is now
# just for scoping a session to a subset. Still pair with a per-lane WORKTREE_ROOT (or a
# separate clone) so the lanes' worktrees can't delete each other.
ONLY_ISSUES="${ONLY_ISSUES:-}"
WORKTREE_ROOT="${WORKTREE_ROOT:-../ralph-worktrees}"
AGENT="${AGENT:-claude}"
# Per-stage models (#21 Delta B). Plan wants a strong reasoner; implement is mostly
# mechanical so a cheaper/faster model suffices. Routed via model_flag at each invocation
# (claude only; no-op for codex). Review/test/lint moved to no-mistakes, which uses its
# own repo-configured agent, so there is no REVIEW_MODEL here.
# PLAN prefers Fable 5 (free for Max subscriptions until 2026-07-07) and falls back to
# PLAN_FALLBACK_MODEL when it can't be called. After the free window, set
# PLAN_MODEL=claude-opus-4-8 to stop the wasted fallback call per plan.
PLAN_MODEL="${PLAN_MODEL:-claude-fable-5}"
PLAN_FALLBACK_MODEL="${PLAN_FALLBACK_MODEL:-claude-opus-4-8}"
CODE_MODEL="${CODE_MODEL:-claude-sonnet-5}"
# Plan stage (#21 Delta A). AUTO_PLAN=1 auto-approves the plan inline (full-auto to the
# gate); default 0 is "semi" — post the plan, park the issue on awaiting-plan, and let a
# human approve by adding plan-approved. The canonical plan always lives in an issue
# comment tagged with PLAN_MARKER so the implement stage can read the approved plan back.
AUTO_PLAN="${AUTO_PLAN:-0}"
PLAN_MARKER="<!-- ralph:plan -->"
PROMPT_DIR="${PROMPT_DIR:-${HERE}/prompts}"
# no-mistakes is the gate. NM_BIN is the CLI; NM_YES=1 (default) runs the autonomous
# path (`axi run --yes`, auto-resolve every gate). Empty NM_YES selects the semi/HITL
# path: a gate pauses the harness and escalates to a human instead of auto-resolving.
NM_BIN="${NM_BIN:-no-mistakes}"
NM_YES="${NM_YES:-1}"
# Herdr integration (optional). git-ralph runs its agents headless, so Herdr's screen
# auto-detection can't classify a lane — the harness reports its own semantic state so the
# Herdr sidebar shows which lane is working/blocked at a glance across parallel lanes.
# Auto-activates only when running INSIDE a Herdr pane (HERDR_PANE_ID set) with `herdr` on
# PATH; a no-op everywhere else. Set RALPH_HERDR=0 to disable even inside a pane.
RALPH_HERDR="${RALPH_HERDR:-1}"
DRY_RUN="${DRY_RUN:-}"
MAX_ITER="${1:-20}"

log() { printf '\033[1;34m[ralph]\033[0m %s\n' "$*"; }

# herdr_report <event-token> [status-text] — best-effort report of this lane's state to
# Herdr's sidebar (see herdr_state_for). Self-addresses via $HERDR_PANE_ID, which Herdr
# sets in each pane. Fully guarded and never fatal: off unless inside a Herdr pane with the
# CLI present. A `blocked` state also fires a desktop notification so an operator is pinged.
herdr_report() {
  [ "$RALPH_HERDR" = 1 ] || return 0
  [ -n "${HERDR_PANE_ID:-}" ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0
  local state status; state="$(herdr_state_for "$1")"; status="${2:-}"
  herdr pane report-agent "$HERDR_PANE_ID" --source git-ralph --agent ralph \
    --state "$state" ${status:+--custom-status "$status"} >/dev/null 2>&1 || true
  [ "$state" = blocked ] \
    && herdr notification show "git-ralph: ${status:-needs a human}" --sound request >/dev/null 2>&1 || true
  return 0
}

# agent_run <prompt-file> [model] — run the configured agent with the prompt's contents,
# selecting a per-stage model when one is given (claude only; no-op for codex) (#21 Delta B).
agent_run() {
  local prompt="$1" model="${2:-}"
  case "$AGENT" in
    # shellcheck disable=SC2046  # model_flag emits 0-or-2 intentional words.
    claude) claude -p $(model_flag "$AGENT" "$model") --dangerously-skip-permissions "$(cat "$prompt")" ;;
    codex)  codex exec --yolo - < "$prompt" ;;
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

# select_next_issue — the next issue to work. Fetches BOTH the ready-for-agent backlog
# and any plan-approved issues (a plan-approved issue has had ready-for-agent removed, so
# a single --label query would miss it), merges/dedupes them, then defers the pure
# priority/exclusion logic to select_issue_from_json (plan-approved first, then P0..P2).
select_next_issue() {
  { gh issue list --repo "$REPO" --state open --label "$AGENT_LABEL" \
      --json number,labels --limit 200
    gh issue list --repo "$REPO" --state open --label "$PLAN_APPROVED_LABEL" \
      --json number,labels --limit 200
  } | jq -s 'add | unique_by(.number)' \
    | select_issue_from_json "$BLOCKED_LABEL" "$AWAITING_PLAN_LABEL" "$PLAN_APPROVED_LABEL" "$ONLY_ISSUES" "$IN_PROGRESS_LABEL"
}

# issue_stage <num> — print "plan" or "implement" for an issue, from its current labels.
issue_stage() {
  local num="$1"
  gh issue view "$num" --repo "$REPO" --json labels -q '.labels' \
    | issue_stage_from_labels "$PLAN_APPROVED_LABEL"
}

# post_plan <num> <plan-text> — post the plan to the issue as the canonical, audit-stable
# record, tagged with PLAN_MARKER so read_approved_plan can find it later.
post_plan() {
  local num="$1" plan_text="$2"
  gh issue comment "$num" --repo "$REPO" \
    --body "$(printf '%s\n\n## Ralph plan\n\n%s' "$PLAN_MARKER" "$plan_text")"
}

# read_approved_plan <num> — print the body of the most recent PLAN_MARKER comment
# (the approved plan), or nothing if there is none.
read_approved_plan() {
  local num="$1"
  gh issue view "$num" --repo "$REPO" --json comments \
    -q ".comments | map(select(.body | contains(\"$PLAN_MARKER\"))) | last | .body // \"\"" \
    2>/dev/null || true
}

# render_plan_html <worktree> <plan-text> — best-effort nicety: if the optional `lavish`
# renderer is on PATH, render the plan to plan.html in the worktree for human review.
# Never fatal — the canonical plan always lives in the issue comment (post_plan).
render_plan_html() {
  local wt="$1" plan_text="$2"
  command -v lavish >/dev/null 2>&1 || return 0
  printf '%s' "$plan_text" | lavish render --output "${wt}/plan.html" >/dev/null 2>&1 || true
}

# run_plan_stage <num> <worktree> <issue-ctx> — generate a plan with PLAN_MODEL (falling
# back to PLAN_FALLBACK_MODEL if PLAN_MODEL can't be called), post it to the issue (always,
# for audit), and render plan.html if lavish is available.
run_plan_stage() {
  local num="$1" wt="$2" issue_ctx="$3" plan_prompt plan_text plan_rc
  plan_prompt="$(mktemp)"
  { prepend_rules "${PROMPT_DIR}/rules.md"; cat "${PROMPT_DIR}/plan.md"; echo;
    echo "## GitHub issue #$num"; echo "$issue_ctx"; } > "$plan_prompt"
  log "Plan (#$num) with model: ${PLAN_MODEL:-<agent default>}"
  set +e
  plan_text="$(cd "$wt" && agent_run "$plan_prompt" "$PLAN_MODEL")"; plan_rc=$?
  if { [ "$plan_rc" -ne 0 ] || [ -z "$plan_text" ]; } \
     && [ -n "$PLAN_FALLBACK_MODEL" ] && [ "$PLAN_FALLBACK_MODEL" != "$PLAN_MODEL" ]; then
    log "Plan model $PLAN_MODEL unavailable (rc=$plan_rc) - falling back to $PLAN_FALLBACK_MODEL"
    plan_text="$(cd "$wt" && agent_run "$plan_prompt" "$PLAN_FALLBACK_MODEL")"
  fi
  set -e
  [ -n "$plan_text" ] || plan_text="(plan agent produced no output)"
  post_plan "$num" "$plan_text"
  render_plan_html "$wt" "$plan_text"
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

# claim_issue <num> — atomically-ish claim a freshly-selected issue: refuse if another
# worker already holds it (carries IN_PROGRESS), else drop it from AGENT_LABEL and stamp
# IN_PROGRESS. Shrinks the collision window from the whole run to a sub-second TOCTOU; the
# file-lock in drain-claimed.sh closes that residual window on a single machine.
claim_issue() {
  local num="$1"
  if gh issue view "$num" --repo "$REPO" --json labels -q '.labels[].name' 2>/dev/null \
       | grep -qx "$IN_PROGRESS_LABEL"; then
    return 1
  fi
  gh issue edit "$num" --repo "$REPO" \
    --add-label "$IN_PROGRESS_LABEL" --remove-label "$AGENT_LABEL" >/dev/null 2>&1 || true
  return 0
}

# run_once — process exactly one issue. Returns 10 when the backlog is empty.
run_once() {
  local num title slug branch wt build_prompt issue_ctx agent_rc stage approved_plan
  local intent axi_out outcome action pr_url try cand

  # Select + claim, skipping issues a concurrent worker grabbed in the race window. Each
  # reselect returns the next candidate (claimed ones lost AGENT_LABEL).
  num=""
  for try in 1 2 3 4 5; do
    cand="$(select_next_issue || true)"
    [ -n "${cand:-}" ] || break
    if claim_issue "$cand"; then num="$cand"; break; fi
    log "issue #$cand already in progress elsewhere — reselecting"
  done
  if [ -z "${num:-}" ]; then
    log "No actionable issues left. <promise>COMPLETE</promise>"
    herdr_report complete "idle"
    return 10
  fi
  log "Selected issue #$num"
  herdr_report working "#$num"

  title="$(gh issue view "$num" --repo "$REPO" --json title -q .title)"
  slug="$(slugify "$title")"
  branch="agent/${num}-${slug}"
  wt="${WORKTREE_ROOT}/wt-${num}"
  stage="$(issue_stage "$num")"
  log "Stage for #$num: $stage"

  git fetch origin "$BASE_BRANCH" --quiet
  if [ -d "$wt" ]; then
    log "Resume worktree $wt"
  else
    mkdir -p "$WORKTREE_ROOT"
    git worktree add -B "$branch" "$wt" "origin/${BASE_BRANCH}"
  fi

  issue_ctx="$(gh issue view "$num" --repo "$REPO" --comments)"

  # ---- Stage 2: Plan (only for fresh issues; plan-approved issues skip straight to 3) ----
  if [ "$stage" = "plan" ]; then
    run_plan_stage "$num" "$wt" "$issue_ctx"
    if [ "$AUTO_PLAN" = "1" ]; then
      log "AUTO_PLAN=1 -> auto-approving plan, implementing inline (#$num)"
      issue_ctx="$(gh issue view "$num" --repo "$REPO" --comments)"  # refresh: include plan
    else
      log "Semi mode -> parking #$num on '$AWAITING_PLAN_LABEL' for human approval"
      gh issue edit "$num" --repo "$REPO" \
        --add-label "$AWAITING_PLAN_LABEL" --remove-label "$AGENT_LABEL" \
        --remove-label "$IN_PROGRESS_LABEL" >/dev/null 2>&1 || true
      herdr_report awaiting-plan "approve plan #$num"
      return 0  # keep the worktree; the loop moves on to the next issue
    fi
  fi

  # ---- Stage 3: Implement against the approved plan ----
  approved_plan="$(read_approved_plan "$num")"
  build_prompt="$(mktemp)"
  { prepend_rules "${PROMPT_DIR}/rules.md"; cat "${PROMPT_DIR}/build.md"; echo;
    if [ -n "$approved_plan" ]; then echo "## Approved plan"; echo "$approved_plan"; echo; fi
    echo "## GitHub issue #$num"; echo "$issue_ctx"; } > "$build_prompt"

  log "Implement (#$num) with model: ${CODE_MODEL:-<agent default>}"
  herdr_report working "impl #$num"
  set +e; ( cd "$wt" && agent_run "$build_prompt" "$CODE_MODEL" ); agent_rc=$?; set -e
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
  herdr_report working "gate #$num"
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
  gh issue edit "$num" --repo "$REPO" \
    --remove-label "$AGENT_LABEL" --remove-label "$PLAN_APPROVED_LABEL" \
    --remove-label "$IN_PROGRESS_LABEL" >/dev/null 2>&1 || true
  herdr_report working "PR ready #$num"
  safe_worktree_remove "$wt"
}

# close_issue_done — terminal `passed`: the PR was merged/closed. Close the issue (in
# case no `Closes #n` auto-closed it), drop the agent/plan labels, and clean up the worktree.
close_issue_done() {
  local num="$1" branch="$2" wt="$3"
  gh issue comment "$num" --repo "$REPO" \
    --body "no-mistakes pipeline passed and the PR merged. Done by ralph-gh (branch \`$branch\`)."
  gh issue edit "$num" --repo "$REPO" \
    --remove-label "$AGENT_LABEL" --remove-label "$PLAN_APPROVED_LABEL" \
    --remove-label "$IN_PROGRESS_LABEL" >/dev/null 2>&1 || true
  gh issue close "$num" --repo "$REPO" 2>/dev/null || true
  herdr_report working "merged #$num"
  safe_worktree_remove "$wt"
}

# mark_needs_human — failure/escalation path. Reap any orphaned gate run for the branch
# (`axi abort` is a no-op when none is active), flag the issue for a human, log where to
# look, and KEEP the worktree for inspection. Does not push, PR, merge, or close.
mark_needs_human() {
  local num="$1" branch="$2" wt="$3" reason="$4"
  [ -d "$wt" ] && ( cd "$wt" && "$NM_BIN" axi abort >/dev/null 2>&1 || true )
  gh issue edit "$num" --repo "$REPO" \
    --add-label "$HUMAN_LABEL" --remove-label "$AGENT_LABEL" \
    --remove-label "$IN_PROGRESS_LABEL" >/dev/null 2>&1 || true
  gh issue comment "$num" --repo "$REPO" \
    --body "ralph-gh stopped ($reason). Inspect branch \`$branch\` / worktree \`$wt\`; see \`no-mistakes axi status\` and \`no-mistakes axi logs --step <step>\`."
  herdr_report needs-human "needs-human #$num"
}

# safe_worktree_remove <worktree-path>
# Unlink any junctions/symlinks inside the worktree BEFORE git removes it, so
# `git worktree remove --force` can't follow a reparse point and delete the real
# target data (#19). On Windows, NTFS junctions need PowerShell to detect reliably.
safe_worktree_remove() {
  local wt="$1" link
  if [ -d "$wt" ]; then
    if is_windows; then
      # -WindowStyle Hidden / -NonInteractive: never flash or block on a console window
      # (the harness can run hundreds of these across a batch).
      powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass \
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
  local num title stage
  num="$(select_next_issue || true)"
  if [ -z "${num:-}" ]; then
    log "DRY-RUN: no actionable issues -> would print <promise>COMPLETE</promise>"
  else
    title="$(gh issue view "$num" --repo "$REPO" --json title -q .title)"
    stage="$(issue_stage "$num")"
    if [ "$stage" = "plan" ] && [ "$AUTO_PLAN" != "1" ]; then
      log "DRY-RUN: would select #$num — $title (stage: plan -> post + await human approval)"
    else
      log "DRY-RUN: would select #$num — $title (stage: $stage)"
    fi
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
