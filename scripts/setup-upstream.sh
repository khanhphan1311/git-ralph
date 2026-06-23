#!/usr/bin/env bash
# setup-upstream.sh — idempotently wire the upstream remote(s) for syncing.
# See SYNC.md for the merge workflow and the "add files, never delete upstream's" rule.
set -euo pipefail

RALPH_UPSTREAM="${RALPH_UPSTREAM:-https://github.com/snarktank/ralph}"

add_remote() { # $1=name $2=url
  if git remote get-url "$1" >/dev/null 2>&1; then
    echo "exists:  $1 -> $(git remote get-url "$1")"
  else
    git remote add "$1" "$2"
    echo "added:   $1 -> $2"
  fi
}

add_remote upstream "$RALPH_UPSTREAM"

echo "Fetching upstream (refs only)…"
git fetch upstream --quiet && echo "fetch:   ok"

echo
echo "Done. To pull updates later:"
echo "  git fetch upstream && git checkout main && git merge upstream/main && npm test"
