#!/bin/bash
# Create the ruhnu sandbox, seed it, and clone the repos. Run on the HOST:
#
#   ./create-sandbox.sh [name]
#
# Environment:
#   RUHNU_CLAUDE_PROJECTS_DIR  host directory mounted at ~/.claude/projects,
#                              holding Claude's session transcripts
#                              (default: ~/.local/share/ruhnu-sbx/claude-projects)
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

# Claude's session transcripts, so `claude --resume` still works after an
# `sbx rm`. A directory of its own, NOT the host's ~/.claude/projects: that one
# holds transcripts for every repo ever opened, and the point is to let this
# sandbox's history out, not to let the host's history in. Override with
# RUHNU_CLAUDE_PROJECTS_DIR to keep a second sandbox's history separate.
SESSIONS_DIR="${RUHNU_CLAUDE_PROJECTS_DIR:-$HOME/.local/share/ruhnu-sbx/claude-projects}"

mkdir -p "$M2_DIR" "$SESSIONS_DIR"

mounts=()
if [ -d "$DATA_DIR" ]; then
    mounts+=("$DATA_DIR")
else
    echo "note: $DATA_DIR not found; creating without it" >&2
fi
mounts+=("$REPO_DIR:/home/agent/ruhnu-sbx")
mounts+=("$M2_DIR:/home/agent/.m2/repository")
mounts+=("$SESSIONS_DIR:/home/agent/.claude/projects")

echo "== creating sandbox '$NAME'"
sbx create --name "$NAME" "$REPO_DIR/kit/" "${mounts[@]}"

# The host's ~/.claude is deliberately NOT mounted: it holds a live OAuth
# token, MCP config that often carries tokens, and transcripts for every repo
# ever opened. Only `projects/` is a mount, and from the dedicated host
# directory above. Copy in the instructions file; mounting projects/ must not
# hide it, since they are siblings. Authentication is separate — run /login
# inside the sandbox and the token stays on the host.
#
# Warn rather than abort if the copy fails: the bootstrap below is the
# expensive part, and losing it to an ssh hiccup over an optional file is a bad
# trade. Re-copy by hand afterwards.
if [ -f "$HOME/.claude/CLAUDE.md" ]; then
    echo "== copying CLAUDE.md"
    if ! { ssh "$NAME.sbx" 'mkdir -p ~/.claude' \
           && scp -q "$HOME/.claude/CLAUDE.md" "$NAME.sbx:/home/agent/.claude/CLAUDE.md"; }; then
        echo "WARNING: could not copy CLAUDE.md; retry with" >&2
        echo "  scp ~/.claude/CLAUDE.md $NAME.sbx:/home/agent/.claude/CLAUDE.md" >&2
    fi
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
