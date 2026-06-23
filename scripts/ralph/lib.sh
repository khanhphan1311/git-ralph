#!/usr/bin/env bash
# lib.sh — pure, sourceable logic for the Ralph harness. No network, no side effects.
# ralph-gh.sh sources this and wires the real gh/git I/O around these functions.

# select_issue_from_json [blocked_label]
# Reads `gh issue list --json number,labels` output on stdin, drops issues carrying
# the blocked label, sorts by priority (P0<P1<P2<unlabelled) then issue number, and
# prints the chosen issue number (or nothing if none qualify).
select_issue_from_json() {
  local blk="${1:-${BLOCKED_LABEL:-blocked}}"
  jq -r --arg blk "$blk" '
    def prio(ls): (ls | map(.name)
      | if index("P0") then 0
        elif index("P1") then 1
        elif index("P2") then 2
        else 3 end);
    map(select(.labels | map(.name) | index($blk) | not))
    | sort_by(prio(.labels), .number)
    | (.[0].number // empty)'
}

# slugify <text>
# Lowercases, collapses non-alphanumerics to single hyphens, trims, and caps at 40
# chars — used to build branch names like agent/<n>-<slug>.
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-40
}

# gate_outcome <agent_rc> <gate_rc> [review_rc]
# Pure decision: prints "finalize" only when every gate passed (rc 0), else
# "needs-human". review_rc defaults to 0 so it's a no-op until #5 wires GATE 2.
gate_outcome() {
  local agent_rc="$1" gate_rc="$2" review_rc="${3:-0}"
  if [ "$agent_rc" -eq 0 ] && [ "$gate_rc" -eq 0 ] && [ "$review_rc" -eq 0 ]; then
    echo finalize
  else
    echo needs-human
  fi
}
