#!/usr/bin/env bats
# Tests for harness_version — pure helper that prints the harness version string.

setup() {
  load "${BATS_TEST_DIRNAME}/../lib.sh"
}

@test "harness_version prints exactly 'git-ralph 0.1.0'" {
  [ "$(harness_version)" = "git-ralph 0.1.0" ]
}
