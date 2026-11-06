#!/bin/bash
# Clone the ruhnu cdoc2 forks into a sandbox and wire them to a shared OpenSpec
# store. Run INSIDE the sandbox:
#
#   scp sbx/bootstrap-ruhnu.sh ruhnu.sbx:/tmp/
#   ssh ruhnu.sbx 'bash /tmp/bootstrap-ruhnu.sh'
#
# Clones land on the VM's own ext4, not a virtiofs mount, so builds run at
# native speed. They live in the 20 GB overlay and are lost on `sbx rm`.
set -euo pipefail

# ~/workspace mirrors the host layout, and is the image's WORKDIR, so `ssh
# ruhnu.sbx` lands next to the repos.
SRC="$HOME/workspace"

# The store id is what repos reference (`store: ruhnu` in openspec/config.yaml)
# and what the machine registry records. The directory name is independent of
# it; this one can become github.com/ruhnu/ruhnu-openspec as-is.
STORE_ID=ruhnu
STORE_DIR=ruhnu-openspec
# Beside the code repos rather than off in ~/openspec, so one VS Code
# multi-root window covers code and specs. It must not be *inside* a git repo,
# and ~/workspace is a plain directory, so this is fine.
STORE_PATH="$SRC/$STORE_DIR"

# repo:branch. The cdoc2 forks all track `develop` — GitHub reports
# cdoc2-auth's default branch as `master`, but that is stale: master sits at
# 0.3.3 while cdoc2-lib expects 0.7.3. Clone develop explicitly rather than
# trusting the default. `.github` is the org profile repo and uses `main`.
REPOS=(
    cdoc2-openapi:develop
    cdoc2-auth:develop
    cdoc2-java-ref-impl:develop
    cdoc2-shares-server:develop
    .github:main
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
    git clone --branch "$branch" "https://github.com/ruhnu/$r" "$SRC/$r"
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

# A multi-root workspace over every repo plus the store, so one VS Code window
# covers the lot. It lives inside the sandbox because that is where the VS Code
# server reads it from; opening it needs --file-uri, not --folder-uri.
WS_FILE="$SRC/ruhnu.code-workspace"
echo "== writing $WS_FILE"
{
    printf '{\n    "folders": [\n'
    sep=""
    for entry in "${REPOS[@]}"; do
        r="${entry%%:*}"
        printf '%s        { "path": "%s" }' "$sep" "$r"
        sep=$',\n'
    done
    printf '%s        { "path": "%s" }\n' "$sep" "$STORE_DIR"
    printf '    ],\n    "settings": {}\n}\n'
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
