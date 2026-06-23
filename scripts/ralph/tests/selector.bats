#!/usr/bin/env bats
# Tests for the Issue selector (pure priority/blocked logic in lib.sh).

setup() {
  load "${BATS_TEST_DIRNAME}/../lib.sh"
}

@test "picks the highest priority issue (P0 over P1 over P2)" {
  json='[
    {"number": 5, "labels": [{"name": "ready-for-agent"}, {"name": "P2"}]},
    {"number": 6, "labels": [{"name": "ready-for-agent"}, {"name": "P0"}]},
    {"number": 7, "labels": [{"name": "ready-for-agent"}, {"name": "P1"}]}
  ]'
  result="$(select_issue_from_json blocked <<<"$json")"
  [ "$result" = "6" ]
}

@test "only P2 issues present -> picks a P2" {
  json='[{"number": 9, "labels": [{"name": "P2"}]}]'
  result="$(select_issue_from_json blocked <<<"$json")"
  [ "$result" = "9" ]
}

@test "same priority -> picks the lower issue number" {
  json='[
    {"number": 12, "labels": [{"name": "P1"}]},
    {"number": 4,  "labels": [{"name": "P1"}]}
  ]'
  result="$(select_issue_from_json blocked <<<"$json")"
  [ "$result" = "4" ]
}

@test "a blocked P0 is skipped in favour of an unblocked lower priority" {
  json='[
    {"number": 3, "labels": [{"name": "P0"}, {"name": "blocked"}]},
    {"number": 8, "labels": [{"name": "P2"}]}
  ]'
  result="$(select_issue_from_json blocked <<<"$json")"
  [ "$result" = "8" ]
}

@test "empty list -> empty output" {
  result="$(select_issue_from_json blocked <<<'[]')"
  [ -z "$result" ]
}

@test "no priority label -> ranked last (after any prioritised issue)" {
  json='[
    {"number": 2, "labels": [{"name": "ready-for-agent"}]},
    {"number": 10, "labels": [{"name": "P2"}]}
  ]'
  result="$(select_issue_from_json blocked <<<"$json")"
  [ "$result" = "10" ]
}
