#!/usr/bin/env bash
# setup-wsl.sh — one-time WSL/Ubuntu setup so git-ralph lanes run WITHOUT the
# native-Windows console-window storm.
#
# On native Windows every child process git-ralph/no-mistakes spawns (git, gh, the
# agent CLI, the test runner, no-mistakes' workers) gets its own console window;
# a multi-lane drain piles up dozens of empty windows that never close. Linux
# processes create no console windows — so run lanes inside WSL/Ubuntu instead.
#
# This installs git-ralph's toolchain USER-LOCAL (no sudo) and clones the harness.
# Project-specific bits (target-repo clone, its test env, no-mistakes init) stay
# manual — see the "Next steps" it prints.
#
# Run inside the Ubuntu terminal:
#   bash setup-wsl.sh
set -euo pipefail

GIT_RALPH_URL="${GIT_RALPH_URL:-https://github.com/khanhphan1311/git-ralph.git}"
BIN="$HOME/.local/bin"; mkdir -p "$BIN"
export PATH="$BIN:$HOME/.no-mistakes/bin:$PATH"

have() { command -v "$1" >/dev/null 2>&1; }
ensure_bashrc() { grep -qF "$1" "$HOME/.bashrc" 2>/dev/null || echo "$1" >> "$HOME/.bashrc"; }
ensure_bashrc 'export PATH="$HOME/.local/bin:$HOME/.no-mistakes/bin:$PATH"'

have git  || { echo "git not found — sudo apt-get install -y git"  >&2; exit 1; }
have curl || { echo "curl not found — sudo apt-get install -y curl" >&2; exit 1; }

echo "== jq =="
have jq || { curl -fsSL https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64 -o "$BIN/jq"; chmod +x "$BIN/jq"; }

echo "== gh (GitHub CLI) =="
if ! have gh; then
  v=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r .tag_name)
  curl -fsSL "https://github.com/cli/cli/releases/download/${v}/gh_${v#v}_linux_amd64.tar.gz" -o /tmp/gh.tgz
  tar -xzf /tmp/gh.tgz -C /tmp && cp "/tmp/gh_${v#v}_linux_amd64/bin/gh" "$BIN/gh"
fi

echo "== no-mistakes =="
have no-mistakes || curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh
export PATH="$HOME/.no-mistakes/bin:$PATH"

echo "== git-ralph =="
[ -d "$HOME/git-ralph/.git" ] || git clone "$GIT_RALPH_URL" "$HOME/git-ralph"
( cd "$HOME/git-ralph" && git pull --ff-only 2>/dev/null || true )

cat <<'NEXT'

==== git-ralph WSL toolchain ready ====
Tools installed user-local: jq, gh, no-mistakes (~/.local/bin, ~/.no-mistakes/bin).
git-ralph cloned to ~/git-ralph. Open a NEW Ubuntu terminal so PATH (~/.bashrc) is live.

Finish the one-time INTERACTIVE logins — these are SEPARATE from your Windows installs:
  gh auth login                 # GitHub (HTTPS -> web browser)
  claude   ->  /login           # your agent CLI (or codex login, per AGENT). The WSL
                                # agent CLI is a separate install + login; without it the
                                # plan/implement stages fail with "agent rc=1 / Not logged in".

Then, per target repo (once):
  gh repo clone <owner/repo> ~/<repo> && cd ~/<repo>
  git fetch --unshallow origin 2>/dev/null || true     # gate push rejects shallow clones
  # set up the project's test toolchain per its README (conda/venv/npm/...).
  # if conda >= 24 blocks env creation on Terms of Service:
  #   conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
  #   conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
  bash ~/git-ralph/scripts/setup-no-mistakes.sh
  bash ~/git-ralph/scripts/setup-labels.sh

Run a lane — no console windows pop up:
  AUTO_PLAN=1 bash ~/git-ralph/scripts/run-lane.sh a "12,13" 5
  # run-lane.sh auto-detects the repo's default branch; override with BASE_BRANCH=<base> if needed.
NEXT
