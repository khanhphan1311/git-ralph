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

# --- #21 Delta A: awaiting-plan excluded, plan-approved ranked first ---

@test "plan-approved is chosen ahead of a higher-priority ready-for-agent" {
  json='[
    {"number": 30, "labels": [{"name": "ready-for-agent"}, {"name": "P0"}]},
    {"number": 31, "labels": [{"name": "awaiting-plan"}, {"name": "P0"}]},
    {"number": 32, "labels": [{"name": "plan-approved"}, {"name": "P2"}]}
  ]'
  result="$(select_issue_from_json blocked awaiting-plan plan-approved <<<"$json")"
  [ "$result" = "32" ]
}

@test "awaiting-plan is skipped like blocked (falls to a ready-for-agent)" {
  json='[
    {"number": 40, "labels": [{"name": "awaiting-plan"}, {"name": "P0"}]},
    {"number": 41, "labels": [{"name": "ready-for-agent"}, {"name": "P2"}]}
  ]'
  result="$(select_issue_from_json blocked awaiting-plan plan-approved <<<"$json")"
  [ "$result" = "41" ]
}

@test "among plan-approved, priority then number still applies" {
  json='[
    {"number": 50, "labels": [{"name": "plan-approved"}, {"name": "P2"}]},
    {"number": 52, "labels": [{"name": "plan-approved"}, {"name": "P0"}]}
  ]'
  result="$(select_issue_from_json blocked awaiting-plan plan-approved <<<"$json")"
  [ "$result" = "52" ]
}

@test "plan-approved overrides a lingering awaiting-plan (still selectable)" {
  json='[
    {"number": 70, "labels": [{"name": "awaiting-plan"}, {"name": "plan-approved"}, {"name": "P2"}]},
    {"number": 71, "labels": [{"name": "ready-for-agent"}, {"name": "P0"}]}
  ]'
  result="$(select_issue_from_json blocked awaiting-plan plan-approved <<<"$json")"
  [ "$result" = "70" ]
}

@test "blocked still wins even with plan-approved (blocked is absolute)" {
  json='[
    {"number": 80, "labels": [{"name": "blocked"}, {"name": "plan-approved"}, {"name": "P0"}]},
    {"number": 81, "labels": [{"name": "ready-for-agent"}, {"name": "P2"}]}
  ]'
  result="$(select_issue_from_json blocked awaiting-plan plan-approved <<<"$json")"
  [ "$result" = "81" ]
}

@test "two equal-priority plan-approved -> lower issue number wins" {
  json='[
    {"number": 61, "labels": [{"name": "plan-approved"}, {"name": "P1"}]},
    {"number": 60, "labels": [{"name": "plan-approved"}, {"name": "P1"}]}
  ]'
  result="$(select_issue_from_json blocked awaiting-plan plan-approved <<<"$json")"
  [ "$result" = "60" ]
}
