#!/usr/bin/env bats
# Tests for is_windows — pure OS detection driven by OSTYPE (overridable).

setup() {
  load "${BATS_TEST_DIRNAME}/../lib.sh"
}

@test "OSTYPE=msys -> windows" {
  OSTYPE=msys is_windows
}

@test "OSTYPE=cygwin -> windows" {
  OSTYPE=cygwin is_windows
}

@test "OSTYPE=linux-gnu -> not windows" {
  OSTYPE=linux-gnu run is_windows
  [ "$status" -ne 0 ]
}

@test "OSTYPE=darwin21 -> not windows" {
  OSTYPE=darwin21 run is_windows
  [ "$status" -ne 0 ]
}
