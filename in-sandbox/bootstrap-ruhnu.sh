#!/bin/bash
# Clone the ruhnu cdoc2 forks into a sandbox and wire them to a shared OpenSpec
# store. Run INSIDE the sandbox:
#
#   ssh ruhnu.sbx 'RUHNU_DATA_DIR=/home/you/workspace/ruhnu-workspace \
#       bash /home/you/workspace/ruhnu-workspace/ruhnu-sbx/in-sandbox/bootstrap-ruhnu.sh'
#
# Everything lands in the data directory, which is mounted from the host at its
# host path — so these are host paths too, and the clones survive `sbx rm`.
# Re-runnable: repos that are already cloned are left alone.
#
# virtiofs rather than the VM's ext4, which costs nothing measurable for a warm
# Maven build (docs/findings.md); a cold resolve was not measured.
set -euo pipefail

# Passed in by create-sandbox.sh. Falls back to the sole mounted candidate, so
# running this by hand needs no arguments in the common case.
SRC="${RUHNU_DATA_DIR:-${1:-}}"
if [ -z "$SRC" ]; then
    candidates=(/home/*/workspace/ruhnu-workspace)
    if [ "${#candidates[@]}" -eq 1 ] && [ -d "${candidates[0]}" ]; then
        SRC="${candidates[0]}"
    else
        echo "error: set RUHNU_DATA_DIR (or pass the data directory as \$1)" >&2
        exit 1
    fi
fi
if [ ! -d "$SRC" ]; then
    echo "error: data directory $SRC is not mounted in this sandbox" >&2
    exit 1
fi

# The store id is what repos reference (`store: ruhnu` in openspec/config.yaml)
# and what the machine registry records. The directory name is independent of
# it; this one is github.com/ruhnu/ruhnu-openspec, cloned below with the code
# repos. A fresh store is created only if that clone fails.
STORE_ID=ruhnu
STORE_DIR=ruhnu-openspec
# Beside the code repos rather than off in ~/openspec, so one VS Code
# multi-root window covers code and specs. It must not be *inside* a git repo,
# and the data directory is a plain directory, so this is fine.
STORE_PATH="$SRC/$STORE_DIR"

# repo:branch. The cdoc2 forks all track `develop` — GitHub reports
# cdoc2-auth's default branch as `master`, but that is stale: master sits at
# 0.3.3 while cdoc2-lib expects 0.7.3. Clone develop explicitly rather than
# trusting the default. `.github` is the org profile repo and uses `main`.
# The OpenSpec store lives on `master`: openspec reads the checked-out branch.
REPOS=(
    cdoc2-openapi:develop
    cdoc2-auth:develop
    cdoc2-java-ref-impl:develop
    cdoc2-shares-server:develop
    .github:main
    "$STORE_DIR":master
)

# Only the code repos get OpenSpec wiring; .github holds the org profile page
# and does not want .claude/ skills committed into it.
OPENSPEC_REPOS=(cdoc2-openapi cdoc2-auth cdoc2-java-ref-impl cdoc2-shares-server)

mkdir -p "$SRC"
for entry in "${REPOS[@]}"; do
    r="${entry%%:*}"
    branch="${entry##*:}"
    if [ -d "$SRC/$r/.git" ]; then
        echo "== $r already cloned, skipping"
        continue
    fi
    echo "== cloning $r ($branch)"
    # Warn rather than abort: the rest of the bootstrap is still worth running.
    git clone --branch "$branch" "https://github.com/ruhnu/$r" "$SRC/$r" \
        || echo "   WARNING: could not clone $r; skipping"
done

# The store's initial commit needs a git identity, and a fresh sandbox has
# none. Take it from GIT_USER_NAME / GIT_USER_EMAIL if given, otherwise fall
# back to a store with no git history rather than failing outright.
#   GIT_USER_NAME="Your Name" GIT_USER_EMAIL=you@example.com bash bootstrap-ruhnu.sh
GIT_INIT_FLAG=()
if ! git config --get user.email > /dev/null 2>&1; then
    if [ -n "${GIT_USER_EMAIL:-}" ] && [ -n "${GIT_USER_NAME:-}" ]; then
        echo "== setting git identity from the environment"
        git config --global user.name "$GIT_USER_NAME"
        git config --global user.email "$GIT_USER_EMAIL"
    else
        echo "== no git identity; creating the store without git history"
        echo "   (set GIT_USER_NAME and GIT_USER_EMAIL to get a real store repo)"
        GIT_INIT_FLAG=(--no-init-git)
    fi
fi

# One store shared by all four repos, so a change spanning the API spec and its
# consumers is a single OpenSpec change rather than four.
if [ ! -d "$STORE_PATH" ]; then
    echo "== creating OpenSpec store '$STORE_ID'"
    openspec store setup "$STORE_ID" --path "$STORE_PATH" "${GIT_INIT_FLAG[@]}"
else
    echo "== store '$STORE_ID' exists; re-registering"
    openspec store register "$STORE_PATH" || true
fi

for r in "${OPENSPEC_REPOS[@]}"; do
    cd "$SRC/$r"
    echo "== wiring $r to the store"
    openspec init --tools claude > /dev/null
    # A repo cannot be both a real OpenSpec root and a store consumer: while
    # these directories exist the `store:` declaration is silently ignored.
    rm -rf openspec/specs openspec/changes
    printf 'schema: spec-driven\nstore: %s\n' "$STORE_ID" > openspec/config.yaml
done

# A multi-root workspace over everything in the data directory — the clones,
# the store, cdoc2-ssh, this repo — so one VS Code window covers the lot. It
# sits in the data directory beside them, which is both a host path and the
# path the VS Code server reads it from. Opening it needs --file-uri, not
# --folder-uri.
WS_FILE="$SRC/ruhnu.code-workspace"
echo "== writing $WS_FILE"

# Whatever is actually there, rather than a hardcoded list: you may have copied
# in repos this script knows nothing about. Relative paths, so the file is
# valid from either side. Hidden directories are skipped.
ws_paths=()
for d in "$SRC"/*/; do
    [ -d "$d" ] || continue
    ws_paths+=("$(basename "$d")")
done

{
    printf '{\n    "folders": [\n'
    sep=""
    for p in "${ws_paths[@]}"; do
        printf '%s        { "path": "%s" }' "$sep" "$p"
        sep=$',\n'
    done
    printf '\n    ],\n    "settings": {}\n}\n'
} > "$WS_FILE"

cd "$SRC/${OPENSPEC_REPOS[0]}"
echo
openspec doctor
echo
echo "Clones:   $SRC"
echo "Store:    $STORE_PATH"
echo "VS Code:  code --file-uri \"vscode-remote://ssh-remote+ruhnu.sbx$WS_FILE\""
echo "Build order: cdoc2-openapi and cdoc2-auth are consumed as artifacts by"
echo "cdoc2-java-ref-impl, so 'mvn install' those two first when building the"
echo "forks rather than consuming upstream releases."
echo
echo "Restart Claude Code before the /opsx:* commands appear."
