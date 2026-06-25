#!/usr/bin/env bats
# Tests for the scoped review findings parser (#21 Delta C). Pure + fail-safe:
# the JSON findings block is authoritative for in/out scope; a bare REVIEW: CLEAN
# line is honoured only when no findings block is present; anything broken is UNCLEAN.

setup() {
  load "${BATS_TEST_DIRNAME}/../lib.sh"
}

# --- review_status: CLEAN / REMEDIATE / UNCLEAN ---

@test "bare REVIEW: CLEAN line (no findings block) -> CLEAN" {
  [ "$(review_status <<<'REVIEW: CLEAN')" = "CLEAN" ]
}

@test "empty findings array -> CLEAN" {
  out='```json
[]
```
REVIEW: CLEAN'
  [ "$(review_status <<<"$out")" = "CLEAN" ]
}

@test "an in-scope finding -> REMEDIATE" {
  out='```json
[{"title":"missing test","scope":"in","severity":"high","detail":"new fn untested"}]
```'
  [ "$(review_status <<<"$out")" = "REMEDIATE" ]
}

@test "only out-of-scope findings -> CLEAN (filed separately, PR not blocked)" {
  out='```json
[{"title":"preexisting smell","scope":"out","severity":"low","detail":"old code"}]
```
REVIEW: CLEAN'
  [ "$(review_status <<<"$out")" = "CLEAN" ]
}

@test "mixed in + out findings -> REMEDIATE" {
  out='```json
[{"title":"a","scope":"out","severity":"low","detail":"x"},
 {"title":"b","scope":"in","severity":"med","detail":"y"}]
```'
  [ "$(review_status <<<"$out")" = "REMEDIATE" ]
}

@test "broken JSON fence -> UNCLEAN (fail-safe)" {
  out='```json
[{"title": broken,,,}
```'
  [ "$(review_status <<<"$out")" = "UNCLEAN" ]
}

@test "broken JSON fence even with a CLEAN line -> UNCLEAN (structured intent failed)" {
  out='```json
[ {bad}
```
REVIEW: CLEAN'
  [ "$(review_status <<<"$out")" = "UNCLEAN" ]
}

@test "no findings block and no CLEAN line -> UNCLEAN (fail-safe)" {
  [ "$(review_status <<<'the diff looks mostly fine but I am unsure')" = "UNCLEAN" ]
}

# --- review_findings <scope>: extract the in/out lists for the orchestrator ---

@test "review_findings in -> only the in-scope findings" {
  out='```json
[{"title":"a","scope":"out","severity":"low","detail":"x"},
 {"title":"b","scope":"in","severity":"med","detail":"y"}]
```'
  [ "$(review_findings in <<<"$out" | jq length)" = "1" ]
  [ "$(review_findings in <<<"$out" | jq -r '.[0].title')" = "b" ]
}

@test "review_findings out -> only the out-of-scope findings" {
  out='```json
[{"title":"a","scope":"out","severity":"low","detail":"x"},
 {"title":"b","scope":"in","severity":"med","detail":"y"}]
```'
  [ "$(review_findings out <<<"$out" | jq length)" = "1" ]
  [ "$(review_findings out <<<"$out" | jq -r '.[0].title')" = "a" ]
}

@test "review_findings on broken JSON -> empty array (never crashes the loop)" {
  out='```json
[ {bad}
```'
  [ "$(review_findings in <<<"$out")" = "[]" ]
}
