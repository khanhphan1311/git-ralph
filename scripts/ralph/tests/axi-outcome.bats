#!/usr/bin/env bats
# Tests for the no-mistakes `axi run` TOON outcome parser + dispatch (pure, in lib.sh).
#
# Fixtures are lifted from kunchenguid/no-mistakes committed evidence files so they
# track the real binary's output shape, not a guess. See the [Kickoff] comment on #23.

setup() {
  load "${BATS_TEST_DIRNAME}/../lib.sh"
}

# ---- parse_axi_outcome: terminal outcomes -------------------------------------

@test "checks-passed (CI green, PR open) -> checks-passed" {
  result="$(parse_axi_outcome <<'TOON'
run:
  id: run-1
  branch: feature/x
  status: running
  head: abcdef12
  pr: "https://github.com/user/repo/pull/42"
  findings: none
  steps[1]{step,status,findings,duration_ms}:
    ci,running,0,0
outcome: checks-passed
help[1]: "CI checks passed - the PR is ready. Ask the user to review and merge it."
TOON
)"
  [ "$result" = "checks-passed" ]
}

@test "terminal completed -> passed" {
  result="$(parse_axi_outcome <<'TOON'
run:
  id: run-2
  branch: feature/x
  status: completed
  head: 99a5b03f
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    review,completed,0,0
    ci,completed,0,0
outcome: passed
help[1]: "Summarize this pipeline run for the user."
TOON
)"
  [ "$result" = "passed" ]
}

@test "terminal failed -> failed" {
  result="$(parse_axi_outcome <<'TOON'
run:
  id: run-3
  branch: feature/x
  status: failed
  head: 99a5b03f
  findings: none
outcome: failed
error: "test step exited 1"
TOON
)"
  [ "$result" = "failed" ]
}

@test "terminal cancelled -> cancelled" {
  result="$(parse_axi_outcome <<'TOON'
run:
  id: run-4
  branch: feature/x
  status: cancelled
outcome: cancelled
TOON
)"
  [ "$result" = "cancelled" ]
}

# ---- parse_axi_outcome: gate (semi-mode decision point) -----------------------

@test "gate block, no outcome -> gate" {
  result="$(parse_axi_outcome <<'TOON'
run:
  id: "01KTQXTYWB68KZ482Q5QETK3PT"
  branch: fix/x
  status: running
  head: 2efbd7a2
  findings: 1 auto-fix
  steps[1]{step,status,findings,duration_ms}:
    review,awaiting_approval,1,0
gate:
  step: review
  status: awaiting_approval
  summary: 1 wording issue for the pipeline to fix
  findings[1]{id,severity,file,action,description}:
    review-1,warning,internal/cli/axi_render.go,auto-fix,Gate wording must say pipeline applies fixes
help[1]: Run `no-mistakes axi respond --action approve` to accept this step
TOON
)"
  [ "$result" = "gate" ]
}

# ---- parse_axi_outcome: fail-safe ---------------------------------------------

@test "empty input -> failed (fail-safe)" {
  result="$(parse_axi_outcome <<<'')"
  [ "$result" = "failed" ]
}

@test "operational error text, no outcome/gate -> failed (fail-safe)" {
  result="$(parse_axi_outcome <<<'error: daemon not running')"
  [ "$result" = "failed" ]
}

@test "indented 'outcome:' inside a finding description is NOT a terminal outcome" {
  # A gate finding can mention the word outcome; only a column-0 key counts.
  result="$(parse_axi_outcome <<'TOON'
run:
  id: run-9
  branch: feature/x
  status: running
gate:
  step: review
  status: awaiting_approval
  findings[1]{id,severity,file,action,description}:
    review-1,warning,docs/x.md,ask-user,Doc should set outcome: passed in the example
help[1]: respond
TOON
)"
  [ "$result" = "gate" ]
}

@test "outcome key takes precedence when both somehow present" {
  result="$(parse_axi_outcome <<'TOON'
gate:
  step: ci
outcome: checks-passed
TOON
)"
  [ "$result" = "checks-passed" ]
}

# ---- gate_has_ask_user --------------------------------------------------------

@test "gate findings containing an ask-user action -> true" {
  run gate_has_ask_user <<'TOON'
gate:
  step: review
  status: awaiting_approval
  findings[2]{id,severity,file,action,description}:
    review-1,warning,a.go,auto-fix,wording
    review-2,error,b.go,ask-user,needs a human decision
TOON
  [ "$status" -eq 0 ]
}

@test "gate findings with only auto-fix/no-op actions -> false" {
  run gate_has_ask_user <<'TOON'
gate:
  step: review
  status: awaiting_approval
  findings[2]{id,severity,file,action,description}:
    review-1,warning,a.go,auto-fix,wording
    review-2,info,b.go,no-op,informational
TOON
  [ "$status" -ne 0 ]
}

@test "no gate at all -> ask-user false" {
  run gate_has_ask_user <<<'outcome: passed'
  [ "$status" -ne 0 ]
}

# ---- parse_axi_pr_url ----------------------------------------------------------

@test "extracts the PR url from the run object" {
  result="$(parse_axi_pr_url <<'TOON'
run:
  id: run-1
  branch: feature/x
  pr: "https://github.com/user/repo/pull/42"
  findings: none
outcome: checks-passed
TOON
)"
  [ "$result" = "https://github.com/user/repo/pull/42" ]
}

@test "no pr field -> empty" {
  result="$(parse_axi_pr_url <<'TOON'
run:
  id: run-3
  branch: feature/x
  status: failed
outcome: failed
TOON
)"
  [ -z "$result" ]
}

# ---- axi_dispatch -------------------------------------------------------------

@test "dispatch checks-passed -> finalize-pr (PR open, leave for human)" {
  [ "$(axi_dispatch checks-passed)" = "finalize-pr" ]
}

@test "dispatch passed -> close-issue (merged)" {
  [ "$(axi_dispatch passed)" = "close-issue" ]
}

@test "dispatch failed -> needs-human" {
  [ "$(axi_dispatch failed)" = "needs-human" ]
}

@test "dispatch cancelled -> needs-human" {
  [ "$(axi_dispatch cancelled)" = "needs-human" ]
}

@test "dispatch gate -> needs-human (autonomous mode should not pause)" {
  [ "$(axi_dispatch gate)" = "needs-human" ]
}

@test "dispatch unknown/blocked -> needs-human (fail-safe)" {
  [ "$(axi_dispatch blocked)" = "needs-human" ]
  [ "$(axi_dispatch '')" = "needs-human" ]
}
