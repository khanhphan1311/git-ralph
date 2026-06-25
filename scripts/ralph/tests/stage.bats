#!/usr/bin/env bats
# Tests for issue_stage_from_labels — routes a selected issue to the plan or
# implement stage based on whether a human has approved its plan (#21 Delta A).

setup() {
  load "${BATS_TEST_DIRNAME}/../lib.sh"
}

@test "labels carrying plan-approved -> implement" {
  result="$(issue_stage_from_labels plan-approved <<<'[{"name":"plan-approved"},{"name":"P1"}]')"
  [ "$result" = "implement" ]
}

@test "fresh ready-for-agent (no plan-approved) -> plan" {
  result="$(issue_stage_from_labels plan-approved <<<'[{"name":"ready-for-agent"},{"name":"P0"}]')"
  [ "$result" = "plan" ]
}

@test "empty label set -> plan" {
  result="$(issue_stage_from_labels plan-approved <<<'[]')"
  [ "$result" = "plan" ]
}
