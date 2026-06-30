#!/usr/bin/env bash
# drain-claimed.sh <issue ...> — drain a pool of issues with an ATOMIC per-issue claim so
# concurrent sessions on this machine NEVER work the same issue. The lock dedupes the pool
# (sessions work-steal), so overlapping/identical issue lists are safe. Run it from EACH
# session's OWN repo clone — the lane id is derived from the clone dir, so NM_HOME and
# worktrees never collide across sessions either.
#
#   (session A)  cd ~/sn-lane-a && drain-claimed.sh 1109 1078 1083
#   (session B)  cd ~/sn-lane-b && drain-claimed.sh 1109 1078 1083   # same list -> they split it
#
# Claim = an atomic `mkdir` under ~/.git-ralph/claims/<issue>; a stale lock whose holder
# PID is dead is reclaimed. Held for the whole run of that issue, released when it finishes.
set -uo pipefail

GR="${GIT_RALPH_DIR:-$HOME/git-ralph}"
CLAIMS="${GIT_RALPH_CLAIMS:-$HOME/.git-ralph/claims}"; mkdir -p "$CLAIMS"
lane="${LANE:-$(basename "$PWD")}"     # unique per clone/session -> NM_HOME/worktree disjoint
ITERS="${ITERS:-1}"

# run-lane.sh (pre-PR-#39) defaults BASE_BRANCH=main; detect the repo's default branch.
if [ -z "${BASE_BRANCH:-}" ]; then
  BASE_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  export BASE_BRANCH="${BASE_BRANCH:-main}"
fi

# Per-lane guard: refuse to run if another live process is already draining THIS clone
# (same lane -> same NM_HOME + worktrees + shared .git would collide). This is exactly the
# "two sessions, same lane" collision — fail loudly instead. Use a separate clone per session.
LANE_LOCK="$CLAIMS/../lane-locks/$lane"; mkdir -p "$(dirname "$LANE_LOCK")"
if ! mkdir "$LANE_LOCK" 2>/dev/null; then
  holder="$(cat "$LANE_LOCK/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    echo "ERROR: lane '$lane' is already being drained by PID $holder from this clone." >&2
    echo "       Run each session from its OWN clone (e.g. ~/sn-lane-a vs ~/sn-lane-b)." >&2
    exit 1
  fi
  rm -rf "$LANE_LOCK"; mkdir "$LANE_LOCK"
fi
echo "$$" > "$LANE_LOCK/pid"
trap 'rm -rf "$LANE_LOCK"' EXIT

claim() {                              # atomic; reclaim if the holder PID is dead
  local d="$CLAIMS/$1"
  if mkdir "$d" 2>/dev/null; then echo "$$" > "$d/pid"; return 0; fi
  local pid; pid="$(cat "$d/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    rm -rf "$d"; mkdir "$d" 2>/dev/null && { echo "$$" > "$d/pid"; return 0; }
  fi
  return 1
}

worked=0
for issue in $(printf '%s ' "$@" | tr ',' ' '); do
  [ -n "$issue" ] || continue
  if ! claim "$issue"; then echo "[skip]  #$issue - claimed by another session"; continue; fi
  echo "[claim] #$issue -> lane '$lane' (base=$BASE_BRANCH)"
  ( AUTO_PLAN="${AUTO_PLAN:-1}" bash "$GR/scripts/run-lane.sh" "$lane" "$issue" "$ITERS" )
  rm -rf "${CLAIMS:?}/$issue"
  worked=$((worked+1))
done
echo "[drain-claimed] lane '$lane' done - worked $worked issue(s)."
