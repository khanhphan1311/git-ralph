#!/usr/bin/env bats
# Tests for herdr_state_for — pure map of a harness event to a Herdr semantic
# agent state (the reportable set: idle/working/blocked/unknown).

setup() {
  load "${BATS_TEST_DIRNAME}/../lib.sh"
}

@test "working -> working" {
  [ "$(herdr_state_for working)" = "working" ]
}

@test "needs-human -> blocked (lane halts for a human)" {
  [ "$(herdr_state_for needs-human)" = "blocked" ]
}

@test "awaiting-plan -> blocked (human must approve the plan)" {
  [ "$(herdr_state_for awaiting-plan)" = "blocked" ]
}

@test "idle -> idle" {
  [ "$(herdr_state_for idle)" = "idle" ]
}

@test "complete -> idle (backlog drained)" {
  [ "$(herdr_state_for complete)" = "idle" ]
}

@test "unrecognized token -> unknown (honest fallback)" {
  [ "$(herdr_state_for whatever)" = "unknown" ]
  [ "$(herdr_state_for '')" = "unknown" ]
}

@test "done is NOT reported as a semantic state (detection-derived) -> unknown" {
  # `done` is a Herdr detection state, not something report-agent accepts; the harness
  # never emits it, so an accidental 'done' token must fall through to the safe default.
  [ "$(herdr_state_for done)" = "unknown" ]
}
