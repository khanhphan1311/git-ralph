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
REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
BASE_BRANCH="${BASE_BRANCH:-main}"
AGENT_LABEL="${AGENT_LABEL:-ready-for-agent}"
HUMAN_LABEL="${HUMAN_LABEL:-needs-human}"
BLOCKED_LABEL="${BLOCKED_LABEL:-blocked}"
WORKTREE_ROOT="${WORKTREE_ROOT:-../ralph-worktrees}"
VALIDATE_CMD="${VALIDATE_CMD:-npm run typecheck && npm test}"
AGENT="${AGENT:-claude}"
PROMPT_DIR="${PROMPT_DIR:-${HERE}/prompts}"
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

# select_next_issue — highest-priority open ready-for-agent issue, not blocked.
select_next_issue() {
  gh issue list --repo "$REPO" --state open --label "$AGENT_LABEL" \
    --json number,labels --limit 200 \
    | select_issue_from_json "$BLOCKED_LABEL"
}

# run_once — process exactly one issue. Returns 10 when the backlog is empty.
run_once() {
  local num title slug branch wt build_prompt issue_ctx agent_rc gate_rc
  local review_rc review_prompt diff_text verdict

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
  { cat "${PROMPT_DIR}/build.md"; echo; echo "## GitHub issue #$num"; echo "$issue_ctx"; } > "$build_prompt"

  set +e; ( cd "$wt" && agent_run "$build_prompt" ); agent_rc=$?; set -e

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
    log "GATE 2: independent review (#$num)"
    diff_text="$(cd "$wt" && git add -A >/dev/null 2>&1 || true; git diff "origin/${BASE_BRANCH}")"
    review_prompt="$(mktemp)"
    { cat "${PROMPT_DIR}/review.md"; echo; echo "## ISSUE #$num"; echo "$issue_ctx";
      echo; echo "## DIFF (origin/${BASE_BRANCH} -> worktree)";
      echo '```diff'; printf '%s\n' "$diff_text"; echo '```'; } > "$review_prompt"
    verdict="$(cd "$wt" && agent_run "$review_prompt" || true)"
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
