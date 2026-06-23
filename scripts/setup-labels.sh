#!/usr/bin/env bash
# setup-labels.sh — idempotently create the operational + triage labels git-ralph uses.
# Safe to re-run: existing labels are skipped, not overwritten.
set -euo pipefail

REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

create() { # $1=name $2=color $3=description
  if gh label create "$1" --repo "$REPO" -c "$2" -d "$3" 2>/dev/null; then
    echo "created: $1"
  else
    echo "exists:  $1"
  fi
}

# Operational labels (driven by ralph-gh.sh)
create ready-for-agent 0E8A16 "Agent can pick this issue up"
create needs-human     D93F0B "A gate failed; a human must look"
create blocked         6A737D "Skipped by the selector until unblocked"
create P0              5319E7 "Priority 0 (highest)"
create P1              5319E7 "Priority 1"
create P2              5319E7 "Priority 2"

# Canonical triage roles
create needs-triage    FBCA04 "Maintainer needs to evaluate"
create needs-info      D4C5F9 "Waiting on reporter"
create ready-for-human 0052CC "Requires human implementation"
create wontfix         FFFFFF "Will not be actioned"

echo "Labels ready on $REPO"
