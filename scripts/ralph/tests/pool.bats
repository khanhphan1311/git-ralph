#!/usr/bin/env bats
# Tests for the pool-token parsers — `<issue>[:model]` annotations let a drain pool pick
# the implement model per issue (hard task -> opus, easy -> default/sonnet).

setup() {
  load "${BATS_TEST_DIRNAME}/../lib.sh"
}

# ---- pool_issue_of ----

@test "bare number -> itself" {
  [ "$(pool_issue_of 1502)" = "1502" ]
}

@test "opus-annotated token -> the number" {
  [ "$(pool_issue_of 1496:opus)" = "1496" ]
}

@test "full-model-id annotation -> the number" {
  [ "$(pool_issue_of 1510:claude-haiku-4-5)" = "1510" ]
}

# ---- pool_model_of ----

@test "bare number -> empty (harness default)" {
  [ -z "$(pool_model_of 1502)" ]
}

@test ":opus shorthand -> claude-opus-4-8" {
  [ "$(pool_model_of 1496:opus)" = "claude-opus-4-8" ]
}

@test ":sonnet shorthand -> claude-sonnet-5" {
  [ "$(pool_model_of 1496:sonnet)" = "claude-sonnet-5" ]
}

@test "full model id passes through verbatim" {
  [ "$(pool_model_of 1510:claude-haiku-4-5)" = "claude-haiku-4-5" ]
}

@test "trailing colon with no model -> empty (harness default)" {
  [ -z "$(pool_model_of 1502:)" ]
}
