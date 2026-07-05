#!/usr/bin/env bash
# watchdog.sh <issue ...> — fully-AFK drain supervisor. Runs drain-claimed.sh over the
# pool; when a run is interrupted (typically the agent's usage limit running out
# mid-drain, which fails the remaining issues as needs-human), it waits until the agent
# is callable again, requeues the failed issues, and relaunches — looping until the pool
# is drained.
#
# Requeue budget: REQUEUE_MAX per issue (default 3). Past that the issue STAYS on
# needs-human for a real human — a genuine bug would otherwise requeue forever.
#
# Requeue = backup-tag the half-done branch (ralph-bak/<N>-<attempt>, local; uncommitted
# worktree WIP is committed into it first), remove the worktree + branch so the next run
# starts clean from the base tip, clear a stale file-claim, relabel
# (-needs-human -in-progress +ready-for-agent), and leave an audit comment.
#
# Also requeues an issue stuck on in-progress whose local claim lock is dead (a
# hard-killed run) — the selector would skip it forever otherwise.
#
# Run ONE watchdog per clone, detached:
#   cd ~/lane-a && nohup bash ~/git-ralph/scripts/watchdog.sh 12 15 18 > ~/watchdog-a.log 2>&1 &
# Several watchdogs (one per clone) may share the SAME pool — drain-claimed.sh's atomic
# claim splits it between them.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="${WATCHDOG_STATE:-$HOME/.git-ralph/watchdog}"; mkdir -p "$STATE"
CLAIMS="${GIT_RALPH_CLAIMS:-$HOME/.git-ralph/claims}"
REQUEUE_MAX="${REQUEUE_MAX:-3}"
PROBE_INTERVAL="${PROBE_INTERVAL:-600}"
AGENT_LABEL="${AGENT_LABEL:-ready-for-agent}"
PLAN_APPROVED_LABEL="${PLAN_APPROVED_LABEL:-plan-approved}"
HUMAN_LABEL="${HUMAN_LABEL:-needs-human}"
IN_PROGRESS_LABEL="${IN_PROGRESS_LABEL:-in-progress}"
lane="${LANE:-$(basename "$PWD")}"
WT_ROOT="${WORKTREE_ROOT:-../ralph-wt-$lane}"
REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

[ $# -gt 0 ] || { echo "usage: watchdog.sh <issue ...>" >&2; exit 1; }
pool="$(printf '%s ' "$@" | tr ',' ' ')"

log() { printf '[watchdog %s] %s\n' "$(date '+%F %T')" "$*"; }

issue_labels() { gh issue view "$1" --repo "$REPO" --json labels -q '.labels[].name' 2>/dev/null; }
issue_state()  { gh issue view "$1" --repo "$REPO" --json state  -q .state 2>/dev/null; }

can_call_agent() {
  timeout 180 claude -p 'Reply with exactly: PONG' 2>/dev/null | grep -q PONG
}

wait_for_agent() {
  until can_call_agent; do
    log "agent not callable (usage limit?) - next probe in ${PROBE_INTERVAL}s"
    sleep "$PROBE_INTERVAL"
  done
}

claim_is_live() {
  local pid
  [ -d "$CLAIMS/$1" ] || return 1
  pid="$(cat "$CLAIMS/$1/pid" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

requeue() {
  local num="$1" attempt="$2" branch wt
  branch="$(git branch --list "agent/${num}-*" --format='%(refname:short)' | head -1)"
  wt="$WT_ROOT/wt-$num"
  if [ -d "$wt" ]; then
    if ! git -C "$wt" diff --quiet 2>/dev/null || ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
      git -C "$wt" add -A >/dev/null 2>&1
      git -C "$wt" commit -qm "wip: watchdog backup before requeue" >/dev/null 2>&1 || true
    fi
    git worktree remove "$wt" --force >/dev/null 2>&1 || true
    git worktree prune >/dev/null 2>&1
  fi
  if [ -n "$branch" ]; then
    git tag -f "ralph-bak/${num}-${attempt}" "$branch" >/dev/null 2>&1 || true
    git branch -D "$branch" >/dev/null 2>&1 || true
  fi
  claim_is_live "$num" || rm -rf "${CLAIMS:?}/${num}" 2>/dev/null || true
  gh issue edit "$num" --repo "$REPO" --add-label "$AGENT_LABEL" \
    --remove-label "$HUMAN_LABEL" --remove-label "$IN_PROGRESS_LABEL" >/dev/null 2>&1 || true
  gh issue comment "$num" --repo "$REPO" --body \
    "watchdog: requeued (attempt ${attempt}/${REQUEUE_MAX}) after the agent became callable again. Prior branch kept as local tag \`ralph-bak/${num}-${attempt}\`." \
    >/dev/null 2>&1 || true
  log "requeued #$num (attempt ${attempt}/${REQUEUE_MAX})"
}

snapshot() {
  local n
  for n in $pool; do
    printf '%s:%s:%s\n' "$n" "$(issue_state "$n")" "$(issue_labels "$n" | sort | tr '\n' ',')"
  done
}

prev_snap=""
while :; do
  runnable=""; to_requeue=""; capped=""; open_left=""
  for n in $pool; do
    [ "$(issue_state "$n")" = "OPEN" ] || continue
    open_left="$open_left $n"
    labels="$(issue_labels "$n")"
    if printf '%s\n' "$labels" | grep -qx "$HUMAN_LABEL" \
       || { printf '%s\n' "$labels" | grep -qx "$IN_PROGRESS_LABEL" && ! claim_is_live "$n"; }; then
      cnt="$(cat "$STATE/$n.requeue" 2>/dev/null || echo 0)"
      if [ "$cnt" -ge "$REQUEUE_MAX" ]; then capped="$capped $n"; else to_requeue="$to_requeue $n"; fi
    elif printf '%s\n' "$labels" | grep -qxE "${AGENT_LABEL}|${PLAN_APPROVED_LABEL}"; then
      runnable="$runnable $n"
    fi
  done

  if [ -z "${to_requeue// }" ] && [ -z "${runnable// }" ]; then
    log "nothing runnable left. still-open:${open_left:- none} | requeue-capped:${capped:- none}"
    break
  fi

  wait_for_agent

  for n in $to_requeue; do
    cnt="$(cat "$STATE/$n.requeue" 2>/dev/null || echo 0)"; cnt=$((cnt+1))
    echo "$cnt" > "$STATE/$n.requeue"
    requeue "$n" "$cnt"
    runnable="$runnable $n"
  done

  log "cycle: draining$runnable"
  # shellcheck disable=SC2086  # word-splitting the pool is intentional
  bash "$HERE/drain-claimed.sh" $runnable || log "drain exited rc=$?"

  snap="$(snapshot)"
  if [ "$snap" = "$prev_snap" ]; then
    log "no progress this cycle (another session may hold the claims) - sleeping ${PROBE_INTERVAL}s"
    sleep "$PROBE_INTERVAL"
  fi
  prev_snap="$snap"
done
log "watchdog done."
