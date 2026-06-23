#!/usr/bin/env bats
# Regression test for the data-loss bug (#19): neutralising reparse points inside a
# worktree must NOT delete the data the junction points at. Windows-only (junctions).

setup() {
  load "${BATS_TEST_DIRNAME}/../lib.sh"
  is_windows || skip "junction test is Windows-only"
  PS1_SCRIPT="$(cygpath -w "${BATS_TEST_DIRNAME}/../safe-worktree-remove.ps1")"
  TARGET_WIN="$(cygpath -w "${BATS_TEST_TMPDIR}/target")"
  WT_DIR="${BATS_TEST_TMPDIR}/wt"
  WT_WIN="$(cygpath -w "$WT_DIR")"
  mkdir -p "${BATS_TEST_TMPDIR}/target" "$WT_DIR"
  echo "SENTINEL" > "${BATS_TEST_TMPDIR}/target/keep.txt"
  cmd //c mklink //J "${WT_WIN}\\linkdir" "$TARGET_WIN" >/dev/null 2>&1
}

@test "ps1 unlinks a junction but preserves the target's data" {
  # sanity: junction exists and resolves to the sentinel before removal
  [ -f "${BATS_TEST_TMPDIR}/wt/linkdir/keep.txt" ]

  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1_SCRIPT" -WorktreePath "$WT_WIN"

  # the junction is gone...
  [ ! -e "${BATS_TEST_TMPDIR}/wt/linkdir" ]
  # ...but the real target data survived
  [ -f "${BATS_TEST_TMPDIR}/target/keep.txt" ]
  [ "$(cat "${BATS_TEST_TMPDIR}/target/keep.txt")" = "SENTINEL" ]
}
