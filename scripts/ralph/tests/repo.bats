#!/usr/bin/env bats
# Regression tests for repo_slug_from_url — must resolve owner/repo from any remote
# URL shape, so REPO pins to `origin` even when an `upstream` remote also exists (#14).

setup() {
  load "${BATS_TEST_DIRNAME}/../lib.sh"
}

@test "https URL with .git suffix" {
  [ "$(repo_slug_from_url 'https://github.com/khanhphan1311/git-ralph.git')" = "khanhphan1311/git-ralph" ]
}

@test "https URL without .git suffix" {
  [ "$(repo_slug_from_url 'https://github.com/khanhphan1311/git-ralph')" = "khanhphan1311/git-ralph" ]
}

@test "scp-style git@ URL" {
  [ "$(repo_slug_from_url 'git@github.com:khanhphan1311/git-ralph.git')" = "khanhphan1311/git-ralph" ]
}

@test "ssh:// URL" {
  [ "$(repo_slug_from_url 'ssh://git@github.com/khanhphan1311/git-ralph.git')" = "khanhphan1311/git-ralph" ]
}
