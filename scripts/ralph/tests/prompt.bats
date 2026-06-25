#!/usr/bin/env bats
# Tests for prepend_rules (pure prompt composer in lib.sh). The harness prepends the
# shared engineering rules to every stage prompt so every spawned agent receives them,
# regardless of backend or host CLAUDE.md auto-loading.

setup() {
  load "${BATS_TEST_DIRNAME}/../lib.sh"
}

@test "existing rules file -> emits its contents" {
  printf '# Rules\n- no em dash\n' > "${BATS_TEST_TMPDIR}/rules.md"
  run prepend_rules "${BATS_TEST_TMPDIR}/rules.md"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "# Rules" ]
  [ "${lines[1]}" = "- no em dash" ]
}

@test "rules are separated from the next content by a blank line" {
  # Write the composed (rules + stage) prompt to a file so the trailing blank line
  # survives inspection — bats trims trailing newlines off \$output.
  printf 'RULE-LINE\n' > "${BATS_TEST_TMPDIR}/rules.md"
  { prepend_rules "${BATS_TEST_TMPDIR}/rules.md"; echo 'STAGE-LINE'; } > "${BATS_TEST_TMPDIR}/out"
  # Expect exactly: RULE-LINE, <blank>, STAGE-LINE.
  [ "$(sed -n '1p' "${BATS_TEST_TMPDIR}/out")" = "RULE-LINE" ]
  [ "$(sed -n '2p' "${BATS_TEST_TMPDIR}/out")" = "" ]
  [ "$(sed -n '3p' "${BATS_TEST_TMPDIR}/out")" = "STAGE-LINE" ]
}

@test "composed build-style prompt carries rules ahead of the stage prompt" {
  printf 'RULE-LINE\n' > "${BATS_TEST_TMPDIR}/rules.md"
  printf 'STAGE-LINE\n' > "${BATS_TEST_TMPDIR}/build.md"
  out="$( { prepend_rules "${BATS_TEST_TMPDIR}/rules.md"; cat "${BATS_TEST_TMPDIR}/build.md"; } )"
  [[ "$out" == *RULE-LINE* ]]
  [[ "$out" == *STAGE-LINE* ]]
  rule_pos="$(printf '%s\n' "$out" | grep -n RULE-LINE | head -1 | cut -d: -f1)"
  stage_pos="$(printf '%s\n' "$out" | grep -n STAGE-LINE | head -1 | cut -d: -f1)"
  [ "$rule_pos" -lt "$stage_pos" ]
}

@test "missing rules file -> prints nothing, returns 0 (non-fatal)" {
  run prepend_rules "${BATS_TEST_TMPDIR}/does-not-exist.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty argument -> prints nothing, returns 0 (non-fatal)" {
  run prepend_rules ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no argument at all -> prints nothing, returns 0 (non-fatal)" {
  run prepend_rules
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a directory path (not a regular file) -> prints nothing, returns 0" {
  run prepend_rules "${BATS_TEST_TMPDIR}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
