#!/bin/bash
# Create the ruhnu sandbox, seed it, and clone the repos. Run on the HOST:
#
#   ./create-sandbox.sh [name]
#
# Unlike the other scripts here, this one runs host-side — it needs sbx, and
# it copies files the sandbox cannot reach by itself.
set -euo pipefail

NAME="${1:-ruhnu}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Mounted from the host. The primary workspace (first, no target) must mount at
# its host path, so cdoc2-ssh takes that slot: it lives on gitlab.cyber.ee over
# SSH, which the sandbox can reach neither by key nor by egress policy, so
# mounting is the only way in.
DATA_DIR="$HOME/workspace/cdoc2-ssh"
M2_DIR="$HOME/.m2/repository"

mkdir -p "$M2_DIR"

mounts=()
if [ -d "$DATA_DIR" ]; then
    mounts+=("$DATA_DIR")
else
    echo "note: $DATA_DIR not found; creating without it" >&2
fi
mounts+=("$REPO_DIR:/home/agent/ruhnu-sbx")
mounts+=("$M2_DIR:/home/agent/.m2/repository")

echo "== creating sandbox '$NAME'"
sbx create --name "$NAME" "$REPO_DIR/kit/" "${mounts[@]}"

# ~/.claude is deliberately NOT mounted: it holds a live OAuth token, MCP
# config that often carries tokens, and transcripts for every repo ever opened.
# Copy in only the instructions file. Authentication is separate — run /login
# inside the sandbox and the token stays on the host.
if [ -f "$HOME/.claude/CLAUDE.md" ]; then
    echo "== copying CLAUDE.md"
    ssh "$NAME.sbx" 'mkdir -p ~/.claude'
    scp -q "$HOME/.claude/CLAUDE.md" "$NAME.sbx:/home/agent/.claude/CLAUDE.md"
else
    echo "note: no ~/.claude/CLAUDE.md to copy" >&2
fi

echo "== bootstrapping repos and the OpenSpec store"
ssh "$NAME.sbx" 'bash /home/agent/ruhnu-sbx/in-sandbox/bootstrap-ruhnu.sh'

cat <<EOF

Sandbox '$NAME' ready.

  shell:   ssh $NAME.sbx
  vscode:  code --file-uri "vscode-remote://ssh-remote+$NAME.sbx/home/agent/workspace/ruhnu.code-workspace"

Run /login inside the sandbox the first time.
EOF
