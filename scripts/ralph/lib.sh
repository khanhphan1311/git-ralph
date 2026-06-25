#!/usr/bin/env bash
# lib.sh — pure, sourceable logic for the Ralph harness. No network, no side effects.
# ralph-gh.sh sources this and wires the real gh/git I/O around these functions.

# select_issue_from_json [blocked_label] [awaiting_label] [approved_label]
# Reads `gh issue list --json number,labels` output on stdin and picks the next issue
# to work. Drops `blocked` issues, and `awaiting-plan` issues UNLESS they also carry
# `plan-approved` (a human approving by adding plan-approved on top of awaiting-plan
# must still be selectable). Among the rest, plan-approved issues rank first (finish what
# a human already vetted), then priority (P0<P1<P2<unlabelled), then issue number. Prints
# the chosen issue number (or nothing if none qualify).
select_issue_from_json() {
  local blk="${1:-${BLOCKED_LABEL:-blocked}}"
  local awaiting="${2:-${AWAITING_PLAN_LABEL:-awaiting-plan}}"
  local approved="${3:-${PLAN_APPROVED_LABEL:-plan-approved}}"
  jq -r --arg blk "$blk" --arg awaiting "$awaiting" --arg approved "$approved" '
    def prio(ls): (ls | map(.name)
      | if index("P0") then 0
        elif index("P1") then 1
        elif index("P2") then 2
        else 3 end);
    def approved_rank(ls): (ls | map(.name) | if index($approved) then 0 else 1 end);
    map(select(.labels | map(.name) as $n
      | (($n | index($blk)) | not)
        and ((($n | index($awaiting)) | not) or (($n | index($approved)) != null))))
    | sort_by(approved_rank(.labels), prio(.labels), .number)
    | (.[0].number // empty)'
}

# issue_stage_from_labels [approved_label]
# Reads a single issue's labels JSON (the `.labels` array) on stdin and prints which
# stage the loop should enter: "implement" when a human has already approved the plan
# (the approved label is present), otherwise "plan" (the issue still needs a plan).
issue_stage_from_labels() {
  local approved="${1:-${PLAN_APPROVED_LABEL:-plan-approved}}"
  jq -r --arg approved "$approved" '
    if (map(.name) | index($approved)) then "implement" else "plan" end'
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

# parse_review_verdict
# Reads a reviewer's output on stdin and prints "PASS" or "FAIL". Fail-safe: PASS
# only when the FIRST non-empty line, trimmed and CR-stripped, equals exactly
# "REVIEW: PASS". Anything else — empty, mid-text occurrence, extra words — is FAIL.
parse_review_verdict() {
  local line first=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [ -n "$line" ]; then first="$line"; break; fi
  done
  if [ "$first" = "REVIEW: PASS" ]; then echo PASS; else echo FAIL; fi
}

# extract_json_block
# Prints the contents of the FIRST ```json fenced block found on stdin (the lines
# between the opening ```json fence and the next ``` fence). Prints nothing when no
# such block exists. This is the seam the scoped-findings reviewer (#21 Delta C) uses
# to hand structured findings to the harness.
extract_json_block() {
  awk '
    /^[[:space:]]*```json[[:space:]]*$/ { infence=1; next }
    infence && /^[[:space:]]*```[[:space:]]*$/ { exit }
    infence { print }
  '
}

# review_findings <scope>
# Reads reviewer output on stdin and prints, as a compact JSON array, the findings
# whose .scope equals <scope> ("in" or "out"). Fail-safe: any missing/broken JSON
# block yields "[]" so the orchestrator loop never crashes on bad model output.
review_findings() {
  local scope="$1" block
  block="$(extract_json_block)"
  printf '%s' "$block" \
    | jq -c --arg s "$scope" '[ .[] | select(.scope == $s) ]' 2>/dev/null \
    || echo '[]'
}

# review_status
# Reads reviewer output on stdin and prints the loop's next move:
#   REMEDIATE — the findings block parsed and has >=1 in-scope finding (auto-fix).
#   CLEAN     — findings parsed with zero in-scope (out-only is filed, not blocking),
#               OR no findings block at all but an explicit `REVIEW: CLEAN` line.
#   UNCLEAN   — fail-safe: a findings fence exists but does NOT parse, or there is no
#               findings block and no CLEAN line. Treated as "still dirty" — never
#               clears the PR on ambiguous output.
# The JSON findings block is authoritative for scope; a bare CLEAN line is honoured
# only when no findings block is present.
review_status() {
  local input block in_count
  input="$(cat)"
  if printf '%s\n' "$input" | grep -qE '^[[:space:]]*```json[[:space:]]*$'; then
    block="$(printf '%s\n' "$input" | extract_json_block)"
    if printf '%s' "$block" | jq -e 'type == "array"' >/dev/null 2>&1; then
      in_count="$(printf '%s' "$block" | jq '[ .[] | select(.scope == "in") ] | length')"
      if [ "${in_count:-0}" -gt 0 ]; then echo REMEDIATE; else echo CLEAN; fi
    else
      echo UNCLEAN
    fi
  elif printf '%s\n' "$input" | grep -qE '^[[:space:]]*REVIEW: CLEAN[[:space:]]*$'; then
    echo CLEAN
  else
    echo UNCLEAN
  fi
}

# harness_version
# Prints the harness version string (`git-ralph <semver>`) to stdout. Pure and
# sourceable — the version is kept in lock-step with package.json's "version".
harness_version() {
  echo "git-ralph 0.1.0"
}

# model_flag <agent> <model>
# Builds the per-stage model selection flag for an agent invocation. Only `claude`
# accepts `--model` today, so it prints `--model <model>`; every other backend (and an
# empty model) prints nothing, letting the agent fall back to its own default. This is
# the seam that lets the harness route PLAN_MODEL/CODE_MODEL/REVIEW_MODEL per stage.
model_flag() {
  local agent="$1" model="${2:-}"
  [ -z "$model" ] && return 0
  case "$agent" in
    claude) printf -- '--model %s' "$model" ;;
    *) ;;
  esac
}

# prepend_rules <rules-file>
# Emits the shared global engineering rules followed by a blank line, so the harness
# can prepend them to EVERY stage prompt (build, review) and thus to every spawned
# agent - independent of backend (claude/codex) or whether the host happens to
# auto-load ~/.claude/CLAUDE.md. A missing or unnamed rules file is non-fatal: prints
# nothing and returns 0, so the stage prompt still runs.
prepend_rules() {
  local rules="${1:-}"
  [ -n "$rules" ] && [ -f "$rules" ] || return 0
  cat "$rules"
  echo
}

# is_windows
# True on Git Bash / MSYS / Cygwin. Reads OSTYPE first (overridable for tests),
# falling back to `uname -s` only when OSTYPE is unset.
is_windows() {
  local os="${OSTYPE:-$(uname -s 2>/dev/null)}"
  case "$os" in
    msys*|cygwin*|win32*|MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# repo_slug_from_url <git-remote-url>
# Extracts owner/repo from any remote URL shape (https / git@ scp / ssh, with or
# without a .git suffix). Used to pin REPO to `origin` rather than letting gh guess
# when multiple remotes (e.g. an upstream) exist.
repo_slug_from_url() {
  printf '%s' "$1" \
    | sed -E 's#\.git$##' \
    | sed -E 's#^.*[/:]([^/]+/[^/]+)$#\1#'
}
