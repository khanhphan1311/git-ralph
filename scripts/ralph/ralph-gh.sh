#!/usr/bin/env bash
# ralph-gh.sh — GitHub-issue/PR-driven Ralph loop + mattpocock skills.
#
# Walking skeleton (slice #3): select -> worktree -> agent -> finalize (happy path).
# Quality gates (validation, independent review) are added in slices #4/#5.
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
# Plan-stage labels (#21 Delta A). `awaiting-plan` parks an issue waiting for a human to
# vet its plan (skipped by the selector like `blocked`); `plan-approved` marks a vetted
# plan so the loop resumes it ahead of fresh work and jumps straight to implement.
AWAITING_PLAN_LABEL="${AWAITING_PLAN_LABEL:-awaiting-plan}"
PLAN_APPROVED_LABEL="${PLAN_APPROVED_LABEL:-plan-approved}"
WORKTREE_ROOT="${WORKTREE_ROOT:-../ralph-worktrees}"
VALIDATE_CMD="${VALIDATE_CMD:-npm run typecheck && npm test}"
AGENT="${AGENT:-claude}"
# Per-stage models (#21 Delta B). Plan/review want a strong reasoner; implement is mostly
# mechanical so a cheaper/faster model suffices. Routed via model_flag at each invocation.
PLAN_MODEL="${PLAN_MODEL:-claude-opus-4-8}"
CODE_MODEL="${CODE_MODEL:-claude-sonnet-4-6}"
REVIEW_MODEL="${REVIEW_MODEL:-claude-opus-4-8}"
# Plan stage (#21 Delta A). AUTO_PLAN=1 auto-approves the plan inline (full-auto to PR);
# default 0 is "semi" — post the plan, park the issue on awaiting-plan, and let a human
# approve by adding plan-approved. The canonical plan always lives in an issue comment,
# tagged with PLAN_MARKER so the implement stage can read the approved plan back.
AUTO_PLAN="${AUTO_PLAN:-0}"
PLAN_MARKER="<!-- ralph:plan -->"
PROMPT_DIR="${PROMPT_DIR:-${HERE}/prompts}"
DRY_RUN="${DRY_RUN:-}"
MAX_ITER="${1:-20}"

log() { printf '\033[1;34m[ralph]\033[0m %s\n' "$*"; }

# agent_run <prompt-file> [model] — run the configured agent with the prompt's contents,
# selecting a per-stage model when one is given (claude only; no-op for codex).
agent_run() {
  local prompt="$1" model="${2:-}"
  case "$AGENT" in
    claude)
      # shellcheck disable=SC2046  # model_flag emits 0-or-2 intentional words.
      claude -p $(model_flag "$AGENT" "$model") --dangerously-skip-permissions "$(cat "$prompt")" ;;
    codex)  codex exec --yolo - < "$prompt" ;;
    *) echo "Unsupported AGENT: $AGENT" >&2; return 2 ;;
  esac
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
    | select_issue_from_json "$BLOCKED_LABEL" "$AWAITING_PLAN_LABEL" "$PLAN_APPROVED_LABEL"
}

# issue_stage — print "plan" or "implement" for an issue, from its current labels.
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
    --body "$(printf '%s\n\n## 📋 Ralph plan\n\n%s' "$PLAN_MARKER" "$plan_text")"
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

# run_plan_stage <num> <worktree> <issue-ctx> — generate a plan with PLAN_MODEL, post it
# to the issue (always, for audit), and render plan.html if lavish is available.
run_plan_stage() {
  local num="$1" wt="$2" issue_ctx="$3" plan_prompt plan_text
  plan_prompt="$(mktemp)"
  { prepend_rules "${PROMPT_DIR}/rules.md"; cat "${PROMPT_DIR}/plan.md"; echo;
    echo "## GitHub issue #$num"; echo "$issue_ctx"; } > "$plan_prompt"
  log "Plan (#$num) with model: ${PLAN_MODEL:-<agent default>}"
  plan_text="$(cd "$wt" && agent_run "$plan_prompt" "$PLAN_MODEL" || true)"
  [ -n "$plan_text" ] || plan_text="(plan agent produced no output)"
  post_plan "$num" "$plan_text"
  render_plan_html "$wt" "$plan_text"
}

# run_once — process exactly one issue. Returns 10 when the backlog is empty.
run_once() {
  local num title slug branch wt build_prompt issue_ctx agent_rc gate_rc
  local review_rc review_prompt diff_text verdict stage approved_plan

  num="$(select_next_issue || true)"
  if [ -z "${num:-}" ]; then
    log "No actionable issues left. <promise>COMPLETE</promise>"
    return 10
  fi
  log "Selected issue #$num"

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
        --add-label "$AWAITING_PLAN_LABEL" --remove-label "$AGENT_LABEL" >/dev/null 2>&1 || true
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
  set +e; ( cd "$wt" && agent_run "$build_prompt" "$CODE_MODEL" ); agent_rc=$?; set -e

  # GATE 1 — validation. Only run it if the agent itself didn't error out.
  gate_rc=0
  if [ "$agent_rc" -eq 0 ]; then
    log "GATE 1: validating (#$num) -> $VALIDATE_CMD"
    set +e; ( cd "$wt" && bash -c "$VALIDATE_CMD" ); gate_rc=$?; set -e
  fi

  # GATE 2 — independent review. A separate reviewer agent reads the diff and emits
  # a verdict; fail-safe parsing means only an explicit first-line PASS clears it.
  review_rc=1
  if [ "$agent_rc" -eq 0 ] && [ "$gate_rc" -eq 0 ]; then
    log "GATE 2: independent review (#$num) with model: ${REVIEW_MODEL:-<agent default>}"
    diff_text="$(cd "$wt" && git add -A >/dev/null 2>&1 || true; git diff "origin/${BASE_BRANCH}")"
    review_prompt="$(mktemp)"
    { prepend_rules "${PROMPT_DIR}/rules.md"; cat "${PROMPT_DIR}/review.md"; echo; echo "## ISSUE #$num"; echo "$issue_ctx";
      echo; echo "## DIFF (origin/${BASE_BRANCH} -> worktree)";
      echo '```diff'; printf '%s\n' "$diff_text"; echo '```'; } > "$review_prompt"
    verdict="$(cd "$wt" && agent_run "$review_prompt" "$REVIEW_MODEL" || true)"
    log "Review verdict line: $(printf '%s' "$verdict" | head -1)"
    [ "$(parse_review_verdict <<<"$verdict")" = "PASS" ] && review_rc=0
  fi

  if [ "$(gate_outcome "$agent_rc" "$gate_rc" "$review_rc")" = "finalize" ]; then
    log "PASS #$num (agent=$agent_rc gate=$gate_rc review=$review_rc) -> finalize"
    finalize "$num" "$title" "$branch" "$wt"
  else
    log "FAIL #$num (agent=$agent_rc gate=$gate_rc review=$review_rc) -> needs-human"
    mark_needs_human "$num" "$branch" "$wt" "agent=$agent_rc, gate=$gate_rc, review=$review_rc"
  fi
}

# mark_needs_human — failure path: flag for a human, log the gate codes, KEEP the
# worktree so it can be inspected. Does not push, PR, or close.
mark_needs_human() {
  local num="$1" branch="$2" wt="$3" reason="$4"
  gh issue edit "$num" --repo "$REPO" \
    --add-label "$HUMAN_LABEL" --remove-label "$AGENT_LABEL" >/dev/null 2>&1 || true
  gh issue comment "$num" --repo "$REPO" \
    --body "ralph-gh stopped ($reason). Inspect branch \`$branch\` / worktree \`$wt\`."
}

# finalize — commit, push, open a draft PR, close the issue, remove the worktree.
finalize() {
  local num="$1" title="$2" branch="$3" wt="$4"
  ( cd "$wt"
    git add -A
    git commit -m "feat: resolve #$num — $title" || true
    git push -u origin "$branch"
    gh pr create --repo "$REPO" --base "$BASE_BRANCH" --head "$branch" \
      --title "Resolve #$num: $title" --body "Closes #$num" --draft 2>/dev/null \
      || gh pr edit "$branch" --repo "$REPO" >/dev/null 2>&1 || true
  )
  gh issue comment "$num" --repo "$REPO" --body "Done by ralph-gh. Branch \`$branch\`, draft PR opened."
  gh issue edit "$num" --repo "$REPO" --remove-label "$AGENT_LABEL" >/dev/null 2>&1 || true
  gh issue close "$num" --repo "$REPO"
  safe_worktree_remove "$wt"
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
