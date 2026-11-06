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

# Without a display, `code` prints "Missing X server or $DISPLAY" and exits,
# which is easy to read as it having done nothing. Say so, and hand over the
# command to run from a graphical session.
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    cat >&2 <<EOF
error: no DISPLAY or WAYLAND_DISPLAY; this shell has no graphical session.
       The sandbox is started. Run this from the desktop:

  code --new-window --file-uri "vscode-remote://ssh-remote+$NAME.sbx$WS"

       Or use --no-vscode for a shell.
EOF
    exit 1
fi

# Run `code` detached from any VS Code that may have spawned this shell.
#
# In a VS Code integrated terminal, VSCODE_IPC_HOOK_CLI points at that
# instance's socket and `code` becomes a shim that talks to it rather than
# starting anything: the URI is handed to the running window (which crashes it
# with SIGTRAP), or, if the socket has gone stale, the command exits silently
# having done nothing. Unsetting the hook makes it behave as it does from a
# plain terminal or the desktop launcher.
#
# --new-window for the same reason from the other direction: never reuse an
# existing window. The sandbox session should not displace what you have open.
#
# bootstrap-ruhnu.sh writes the workspace file. Without it there is nothing
# multi-root to open, and opening the missing path gives an empty window.
code_detached() {
    env -u VSCODE_IPC_HOOK_CLI -u VSCODE_GIT_IPC_HANDLE \
        code --new-window "$@"
}

if ssh "$NAME.sbx" "test -f $WS" 2> /dev/null; then
    echo "== opening $WS"
    code_detached --file-uri "vscode-remote://ssh-remote+$NAME.sbx$WS"
else
    echo "note: $WS missing; run in-sandbox/bootstrap-ruhnu.sh in the sandbox" >&2
    echo "== opening /home/agent/workspace instead"
    code_detached --folder-uri "vscode-remote://ssh-remote+$NAME.sbx/home/agent/workspace"
fi
