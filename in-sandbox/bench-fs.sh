#!/bin/bash
# Does keeping the repos on the host-mounted data directory (virtiofs) cost
# anything against the VM's own overlay (ext4)? Run INSIDE the sandbox:
#
#   DATA=~/workspace/ruhnu-workspace
#   ssh ruhnu.sbx "bash $DATA/ruhnu-sbx/in-sandbox/bench-fs.sh [repo]"
#
# Takes about 10 minutes. Copies the repo to /home/agent/bench-ext4 and builds
# it in both places, alternating, so a warming host page cache or a busy
# machine hits both arms rather than one.
#
# What is NOT controlled: ~/.m2/repository is mounted either way, so the
# dependency cache is virtiofs in both arms. That is deliberate — it is how the
# sandbox actually runs, and it was measured separately (docs/findings.md).
# The cold arm below gives each build its own local repo, which is where the
# thousands-of-small-files writes show up if they are going to.
set -euo pipefail

REPO="${1:-cdoc2-java-ref-impl}"
RUNS=3

SRC="${RUHNU_DATA_DIR:-}"
if [ -z "$SRC" ]; then
    candidates=(/home/*/workspace/ruhnu-workspace)
    [ -d "${candidates[0]}" ] && SRC="${candidates[0]}"
fi
[ -n "$SRC" ] && [ -d "$SRC/$REPO" ] || {
    echo "error: no $REPO under the data directory; set RUHNU_DATA_DIR" >&2; exit 1; }

VIRTIOFS="$SRC/$REPO"
EXT4="/home/agent/bench-ext4/$REPO"

mvn_cmd() { if [ -x "$1/mvnw" ]; then echo "./mvnw"; else echo "mvn"; fi; }

# Wall clock in milliseconds — `git status` runs in well under a second, and
# whole seconds measure nothing there. `time` writes to stderr and is a
# keyword, so measure with date instead.
#
# One log per label, not one shared file: a failing arm's log must survive the
# runs that come after it.
LOGDIR=/tmp/bench-fs
run() {
    local label="$1" dir="$2"; shift 2
    local log="$LOGDIR/$(echo "$label" | tr -cs 'a-zA-Z0-9' '-').log"
    cd "$dir"
    local start=$(date +%s%3N)
    if ! "$@" > "$log" 2>&1; then
        echo "$label FAILED, see $log:"; tail -5 "$log"; return 0
    fi
    local ms=$(( $(date +%s%3N) - start ))
    printf '%-28s %d.%03ds\n' "$label" "$((ms / 1000))" "$((ms % 1000))"
}

echo "== copying $REPO to the overlay"
mkdir -p "$LOGDIR"
rm -rf "$EXT4"; mkdir -p "$(dirname "$EXT4")"
cp -a "$VIRTIOFS" "$EXT4"

echo "== filesystems"
findmnt -no SOURCE,FSTYPE "$VIRTIOFS" || true
findmnt -no SOURCE,FSTYPE /home/agent || true

MVN_V="$(mvn_cmd "$VIRTIOFS")"
MVN_E="$(mvn_cmd "$EXT4")"

echo
echo "== warming the dependency cache (online, not timed)"
(cd "$VIRTIOFS" && $MVN_V -B -q clean install -DskipTests > /tmp/bench-warm.log 2>&1) \
    || { echo "warm-up build failed; see /tmp/bench-warm.log"; tail -20 /tmp/bench-warm.log; exit 1; }

echo
echo "== warm offline build, alternating ($RUNS runs each)"
for i in $(seq 1 "$RUNS"); do
    run "virtiofs  run $i" "$VIRTIOFS" $MVN_V -B -o -q clean install -DskipTests
    run "ext4      run $i" "$EXT4"     $MVN_E -B -o -q clean install -DskipTests
done

echo
echo "== many small files: copy a fixed tree onto each filesystem, then delete it"
echo "   (the case the warm build never exercises, and where virtiofs hurt before)"
#
# A cold `mvn install` into a private local repo was the obvious test and the
# wrong one: it needs cdoc2-openapi and cdoc2-auth installed first, so it fails
# in both arms and measures the network when it does not. The dependency cache
# is the same shape of data — tens of thousands of small files — and copying it
# isolates the writes. The SOURCE is the same mounted directory for both arms,
# so only the destination filesystem varies.
CORPUS="$HOME/.m2/repository"
echo "   corpus: $CORPUS ($(du -sh "$CORPUS" 2>/dev/null | cut -f1), $(find "$CORPUS" -type f 2>/dev/null | wc -l) files)"
rm -rf "$VIRTIOFS/.bench-copy" "$EXT4/.bench-copy"
run "virtiofs  copy in"  /tmp cp -a "$CORPUS" "$VIRTIOFS/.bench-copy"
run "ext4      copy in"  /tmp cp -a "$CORPUS" "$EXT4/.bench-copy"
run "virtiofs  stat all" "$VIRTIOFS/.bench-copy" find . -type f -newer /etc/hostname
run "ext4      stat all" "$EXT4/.bench-copy"     find . -type f -newer /etc/hostname
run "virtiofs  delete"   /tmp rm -rf "$VIRTIOFS/.bench-copy"
run "ext4      delete"   /tmp rm -rf "$EXT4/.bench-copy"

echo
echo "== git on a large tree (metadata-heavy, where virtiofs usually hurts)"
for i in $(seq 1 "$RUNS"); do
    run "virtiofs  git status $i" "$VIRTIOFS" git status --porcelain
    run "ext4      git status $i" "$EXT4"     git status --porcelain
done

echo
echo "Logs in $LOGDIR. Clean up with:"
echo "  rm -rf /home/agent/bench-ext4 $LOGDIR '$VIRTIOFS/.bench-copy'"
