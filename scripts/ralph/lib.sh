#!/usr/bin/env bash
# lib.sh — pure, sourceable logic for the Ralph harness. No network, no side effects.
# ralph-gh.sh sources this and wires the real gh/git I/O around these functions.

# select_issue_from_json [blocked_label] [awaiting_label] [approved_label] [only_issues]
# Reads `gh issue list --json number,labels` output on stdin and picks the next issue
# to work. Drops `blocked` issues, and `awaiting-plan` issues UNLESS they also carry
# `plan-approved` (a human approving by adding plan-approved on top of awaiting-plan
# must still be selectable). When `only_issues` (a comma/space-separated allowlist of
# issue numbers) is non-empty, only those issues are eligible — this is how parallel
# lanes claim disjoint issues so they never collide on a branch/worktree. Among the rest,
# plan-approved issues rank first (finish what a human already vetted), then priority
# (P0<P1<P2<unlabelled), then issue number. Prints the chosen issue number (or nothing).
select_issue_from_json() {
  local blk="${1:-${BLOCKED_LABEL:-blocked}}"
  local awaiting="${2:-${AWAITING_PLAN_LABEL:-awaiting-plan}}"
  local approved="${3:-${PLAN_APPROVED_LABEL:-plan-approved}}"
  local only="${4:-${ONLY_ISSUES:-}}"
  jq -r --arg blk "$blk" --arg awaiting "$awaiting" --arg approved "$approved" --arg only "$only" '
    def prio(ls): (ls | map(.name)
      | if index("P0") then 0
        elif index("P1") then 1
        elif index("P2") then 2
        else 3 end);
    def approved_rank(ls): (ls | map(.name) | if index($approved) then 0 else 1 end);
    ($only | gsub("[,]"; " ") | split(" ") | map(select(length > 0) | tonumber)) as $allow
    | map(select(
      (.labels | map(.name) as $n
        | (($n | index($blk)) | not)
          and ((($n | index($awaiting)) | not) or (($n | index($approved)) != null)))
      and ($allow == [] or (.number as $num | $allow | index($num)))))
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

# parse_axi_outcome
# Reads `no-mistakes axi run` TOON on stdin and prints a single outcome token.
# The pipeline emits a `run:` object then EXACTLY ONE of a top-level `outcome:` key
# (`checks-passed`, `passed`, `failed`, `cancelled`, ...) or a top-level `gate:` block
# (a semi-mode approval pause). Precedence: an `outcome:` wins; else a `gate:` -> "gate";
# else fail-safe "failed" (empty / error / unrecognized) so the harness escalates to a
# human and never silently finalizes. Keys are matched ONLY at column 0 — finding
# descriptions legitimately contain the words "outcome"/"gate" and must not be mistaken
# for the terminal key.
parse_axi_outcome() {
  local line outcome="" gate=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      outcome:*)
        [ -n "$outcome" ] && continue
        outcome="${line#outcome:}"
        outcome="$(printf '%s' "$outcome" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        ;;
      gate:*) gate=1 ;;
    esac
  done
  if [ -n "$outcome" ]; then printf '%s\n' "$outcome"
  elif [ -n "$gate" ]; then echo gate
  else echo failed
  fi
}

# gate_has_ask_user
# Reads axi TOON on stdin; exits 0 when a gate finding carries an `ask-user` action,
# else non-zero. Gate finding rows are CSV `id,severity,file,action,description`, so an
# ask-user action surfaces as the `,ask-user,` token. Matching the token errs toward
# escalation (the safe direction) if a description ever embeds it. Used in semi mode to
# route ask-user gates to a human while auto-fix gates get an `axi respond --action fix`.
gate_has_ask_user() {
  grep -q ',ask-user,'
}

# parse_axi_pr_url
# Reads axi TOON on stdin and prints the pull-request URL from the `run:` object's
# `pr:` field (quotes stripped), or nothing when absent/empty. The harness uses it to
# attach `Closes #n` to the PR no-mistakes opened. Only a real `pr:` key (any indent)
# matches — substrings like `expr:` do not — and the first non-empty value wins.
parse_axi_pr_url() {
  local line v
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if printf '%s' "$line" | grep -qE '^[[:space:]]*pr:[[:space:]]'; then
      v="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*pr:[[:space:]]*//; s/^"//; s/"$//')"
      if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
    fi
  done
  return 0
}

# axi_dispatch <outcome-token>
# Pure decision: maps a parsed axi outcome onto the harness action.
#   checks-passed -> finalize-pr  (CI green, PR open; add Closes #n + label, leave merge to a human)
#   passed        -> close-issue  (PR merged/closed; close the issue, clean up)
#   * (failed/cancelled/gate/blocked/unknown/empty) -> needs-human (fail-safe)
axi_dispatch() {
  case "${1:-}" in
    checks-passed) echo finalize-pr ;;
    passed)        echo close-issue ;;
    *)             echo needs-human ;;
  esac
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
