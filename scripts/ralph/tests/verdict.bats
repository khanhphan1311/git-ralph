#!/usr/bin/env bats
# Tests for the review Verdict parser (pure, fail-safe, in lib.sh).

setup() {
  load "${BATS_TEST_DIRNAME}/../lib.sh"
}

@test "first line exactly 'REVIEW: PASS' -> PASS" {
  result="$(parse_review_verdict <<<'REVIEW: PASS
- acceptance criteria met
- covered by tests')"
  [ "$result" = "PASS" ]
}

@test "first line 'REVIEW: FAIL' -> FAIL" {
  result="$(parse_review_verdict <<<'REVIEW: FAIL
- missing tests')"
  [ "$result" = "FAIL" ]
}

@test "no verdict line at all -> FAIL (fail-safe)" {
  result="$(parse_review_verdict <<<'the change looks fine to me')"
  [ "$result" = "FAIL" ]
}

@test "empty input -> FAIL (fail-safe)" {
  result="$(parse_review_verdict <<<'')"
  [ "$result" = "FAIL" ]
}

@test "PASS only mid-text, first line is something else -> FAIL" {
  result="$(parse_review_verdict <<<'Summary of review:
the REVIEW: PASS criteria were not actually met')"
  [ "$result" = "FAIL" ]
}

@test "leading blank lines then 'REVIEW: PASS' -> PASS" {
  result="$(parse_review_verdict <<<'

REVIEW: PASS')"
  [ "$result" = "PASS" ]
}

@test "trailing carriage return on verdict line -> PASS" {
  printf 'REVIEW: PASS\r\n- ok\r\n' > "${BATS_TEST_TMPDIR}/crlf.txt"
  result="$(parse_review_verdict < "${BATS_TEST_TMPDIR}/crlf.txt")"
  [ "$result" = "PASS" ]
}
