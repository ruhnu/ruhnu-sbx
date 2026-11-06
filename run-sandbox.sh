#!/bin/bash
# Start the ruhnu sandbox and open VS Code on it. Run on the HOST:
#
#   ./run-sandbox.sh                 # start, open VS Code
#   ./run-sandbox.sh --no-vscode     # start, drop into a shell instead
#   ./run-sandbox.sh myname          # a sandbox other than 'ruhnu'
set -euo pipefail

NAME=ruhnu
VSCODE=1

for arg in "$@"; do
    case "$arg" in
        --no-vscode) VSCODE=0 ;;
        -h|--help) sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        -*) echo "unknown option: $arg" >&2; exit 1 ;;
        *) NAME="$arg" ;;
    esac
done

if ! sbx ls 2> /dev/null | awk '{print $1}' | grep -qx "$NAME"; then
    echo "error: no sandbox named '$NAME'. Create it with ./create-sandbox.sh" >&2
    exit 1
fi

# `sbx start` on an already-running sandbox is harmless, so don't bother
# parsing state out of `sbx ls`.
echo "== starting $NAME"
sbx start "$NAME" > /dev/null 2>&1 || true

WS=/home/agent/workspace/ruhnu.code-workspace

if [ "$VSCODE" = "0" ]; then
    exec ssh "$NAME.sbx"
fi

if ! command -v code > /dev/null; then
    echo "error: 'code' is not on PATH; use --no-vscode" >&2
    exit 1
fi

# --new-window: without it the CLI hands the URI to an already-running VS Code,
# and that handoff crashes with SIGTRAP when another window is open. A separate
# window is wanted here anyway — the sandbox session should not displace
# whatever else you have open.
#
# bootstrap-ruhnu.sh writes the workspace file. Without it there is nothing
# multi-root to open, and opening the missing path gives an empty window.
if ssh "$NAME.sbx" "test -f $WS" 2> /dev/null; then
    echo "== opening $WS"
    code --new-window --file-uri "vscode-remote://ssh-remote+$NAME.sbx$WS"
else
    echo "note: $WS missing; run in-sandbox/bootstrap-ruhnu.sh in the sandbox" >&2
    echo "== opening /home/agent/workspace instead"
    code --new-window --folder-uri "vscode-remote://ssh-remote+$NAME.sbx/home/agent/workspace"
fi
