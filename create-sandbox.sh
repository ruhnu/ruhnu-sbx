#!/bin/bash
# Create the ruhnu sandbox, seed it, and clone the repos. Run on the HOST:
#
#   ./create-sandbox.sh [name] [--data-dir PATH]
#
# Environment:
#   RUHNU_DATA_DIR             host directory holding everything you work on:
#                              the cloned repos, the OpenSpec store, cdoc2-ssh,
#                              this repo, the VS Code workspace file
#                              (default: ~/workspace/ruhnu-workspace)
#   RUHNU_CLAUDE_PROJECTS_DIR  host directory mounted at ~/.claude/projects,
#                              holding Claude's session transcripts
#                              (default: ~/.local/share/ruhnu-sbx/claude-projects)
#
# Unlike the other scripts here, this one runs host-side — it needs sbx, and
# it copies files the sandbox cannot reach by itself.
set -euo pipefail

NAME=ruhnu
DATA_DIR="${RUHNU_DATA_DIR:-$HOME/workspace/ruhnu-workspace}"

while [ $# -gt 0 ]; do
    case "$1" in
        --data-dir) DATA_DIR="${2:?--data-dir needs a path}"; shift 2 ;;
        --data-dir=*) DATA_DIR="${1#*=}"; shift ;;
        -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 1 ;;
        *) NAME="$1"; shift ;;
    esac
done

# Absolute, because it is mounted at its host path and both sides must agree
# on it. `mkdir -p` first so realpath has something to resolve.
mkdir -p "$DATA_DIR"
DATA_DIR="$(cd "$DATA_DIR" && pwd)"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

M2_DIR="$HOME/.m2/repository"

# Claude's session transcripts, so `claude --resume` still works after an
# `sbx rm`. A directory of its own, NOT the host's ~/.claude/projects: that one
# holds transcripts for every repo ever opened, and the point is to let this
# sandbox's history out, not to let the host's history in. Override with
# RUHNU_CLAUDE_PROJECTS_DIR to keep a second sandbox's history separate.
SESSIONS_DIR="${RUHNU_CLAUDE_PROJECTS_DIR:-$HOME/.local/share/ruhnu-sbx/claude-projects}"

mkdir -p "$M2_DIR" "$SESSIONS_DIR"

# The data directory takes the primary slot — first, and with no target. The
# primary workspace is rejected with HOST:TARGET and mounts at its host path,
# which is what we want anyway: one absolute path for every repo on both sides,
# so ssh, the workspace file, stack traces and Claude's cwd-keyed transcripts
# all agree. Everything else that used to be mounted separately (this repo,
# cdoc2-ssh) is a subdirectory of it now.
mounts=("$DATA_DIR")

# Unless this repo lives outside the data directory, in which case it still
# needs a mount of its own — also at its host path, so the bootstrap is at the
# same place on both sides.
case "$REPO_DIR/" in
    "$DATA_DIR"/*) ;;
    *) mounts+=("$REPO_DIR") ;;
esac

mounts+=("$M2_DIR:/home/agent/.m2/repository")
mounts+=("$SESSIONS_DIR:/home/agent/.claude/projects")

echo "== creating sandbox '$NAME'"
echo "   data dir: $DATA_DIR"
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
# Both paths are host paths, valid unchanged inside the sandbox because both
# directories mount where they already live.
ssh "$NAME.sbx" "RUHNU_DATA_DIR='$DATA_DIR' bash '$REPO_DIR/in-sandbox/bootstrap-ruhnu.sh'"

cat <<EOF

Sandbox '$NAME' ready.

  shell:   ssh $NAME.sbx
  data:    $DATA_DIR (same path on both sides)
  vscode:  ./run-sandbox.sh $NAME

Run /login inside the sandbox the first time.
EOF
