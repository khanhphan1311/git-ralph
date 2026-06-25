#!/usr/bin/env bash
# setup-no-mistakes.sh — idempotently set up the no-mistakes gate for this repo (#23).
#
# Run ONCE per clone. It initializes the local bare gate, installs the /no-mistakes
# agent skill, and ensures the daemon is up. `no-mistakes init` is idempotent: re-running
# refreshes wiring and reports "Gate already initialized (refreshed)".
#
# Prerequisite: the `no-mistakes` binary on PATH. Install it with:
#   macOS/Linux: curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh
#   Windows:     irm https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.ps1 | iex
set -euo pipefail

NM_BIN="${NM_BIN:-no-mistakes}"

if ! command -v "$NM_BIN" >/dev/null 2>&1; then
  cat >&2 <<EOF
no-mistakes ($NM_BIN) is not on PATH. Install it, then re-run this script:
  macOS/Linux: curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh
  Windows:     irm https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.ps1 | iex
EOF
  exit 1
fi

echo "doctor:  checking prerequisites…"
"$NM_BIN" doctor || true

echo "init:    initializing/refreshing the gate (idempotent)…"
# Pass --fork-url via NM_FORK_URL for the fork-contribution flow (origin = parent).
if [ -n "${NM_FORK_URL:-}" ]; then
  "$NM_BIN" init --fork-url "$NM_FORK_URL"
else
  "$NM_BIN" init
fi

echo "daemon:  ensuring the gate daemon is running…"
"$NM_BIN" daemon start >/dev/null 2>&1 || true
"$NM_BIN" daemon status || true

echo
echo "Done. Reminder: commit .no-mistakes.yaml to the DEFAULT branch (main) — the daemon"
echo "reads commands.test/agent from there, not from gated feature branches."
