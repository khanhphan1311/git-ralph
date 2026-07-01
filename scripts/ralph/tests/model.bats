#!/usr/bin/env bats
# Tests for per-stage model routing (pure flag builder in lib.sh).

setup() {
  load "${BATS_TEST_DIRNAME}/../lib.sh"
}

@test "claude + model -> '--model <model>'" {
  result="$(model_flag claude claude-opus-4-8)"
  [ "$result" = "--model claude-opus-4-8" ]
}

@test "claude + a different model -> that model" {
  result="$(model_flag claude claude-sonnet-5)"
  [ "$result" = "--model claude-sonnet-5" ]
}

@test "codex + model -> empty (no-op until codex supports --model)" {
  result="$(model_flag codex claude-opus-4-8)"
  [ -z "$result" ]
}

@test "claude + empty model -> empty (fall back to agent default)" {
  result="$(model_flag claude '')"
  [ -z "$result" ]
}

@test "unknown agent + model -> empty (no flag injected)" {
  result="$(model_flag someagent claude-opus-4-8)"
  [ -z "$result" ]
}
