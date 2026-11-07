#!/bin/bash
# Run INSIDE a sandbox built from kit/claude-sbx.yaml:
#   DATA=~/workspace/ruhnu-workspace
#   ssh ruhnu.sbx "bash $DATA/ruhnu-sbx/in-sandbox/verify-kit.sh"
#
# A host path, valid unchanged inside the sandbox: the data directory mounts
# where it already lives. Do not write ~ here — that is /home/agent inside.
#
# Checks the toolchain, the credential placeholder, and whether Maven can
# actually resolve a cdoc2 artifact from GitHub Packages through the proxy.

hr() { printf '\n=== %s\n' "$1"; }

hr "toolchain"
for t in java javac mvn git gh rg jq docker node openspec claude; do
    printf '%-9s %s\n' "$t" "$(command -v $t || echo '-- missing')"
done
java -version 2>&1 | head -1
mvn -v 2>/dev/null | head -1
openspec --version 2>&1 | head -1
echo "JAVA_HOME=$JAVA_HOME"
echo "alternative JDKs:"; ls -d /usr/lib/jvm/*/ 2>/dev/null

hr "docker engine (no dockerd@1 capability was declared)"
docker info > /dev/null 2>&1 && echo "engine reachable" || {
    echo "engine NOT reachable:"; docker info 2>&1 | tail -3; }

hr "credentials: placeholders only, never real tokens"
# Both of these are sbx placeholders, not secrets.
echo "GH_TOKEN=${GH_TOKEN:-<unset>}"
echo "MAVEN_GH_TOKEN=${MAVEN_GH_TOKEN:-<unset>}"

hr "disk: the overlay is the constraint, not the 935G host disk"
df -hT / "$HOME" 2>&1

hr "maven settings in place"
ls -l "$HOME/.m2/settings.xml" 2>&1

hr "claude session transcripts: mounted, writable, siblings intact"
# ~/.claude/projects is mounted from the host so sessions outlive `sbx rm`.
# Mounting it must not hide its siblings — CLAUDE.md and, after /login,
# .credentials.json — the way mounting ~/.m2 would hide settings.xml.
ls -la "$HOME/.claude" 2>&1
if command -v findmnt > /dev/null; then
    findmnt -no SOURCE,FSTYPE,OPTIONS "$HOME/.claude/projects" \
        || echo "NOT A MOUNT POINT -- sessions will not survive sbx rm"
else
    grep -F " $HOME/.claude/projects " /proc/mounts \
        || echo "NOT A MOUNT POINT -- sessions will not survive sbx rm"
fi
if touch "$HOME/.claude/projects/.verify-kit" 2>/dev/null; then
    rm -f "$HOME/.claude/projects/.verify-kit"; echo "writable OK"
else
    echo "NOT WRITABLE by agent -- Claude cannot record sessions"
fi
[ -f "$HOME/.claude/CLAUDE.md" ] && echo "CLAUDE.md present" \
    || echo "CLAUDE.md MISSING -- hidden by the mount, or never copied"

hr "THE TEST: resolve a cdoc2 artifact from GitHub Packages"
# Exercises kit/m2-settings.xml -> MAVEN_GH_TOKEN placeholder -> proxy
# substitution -> maven.pkg.github.com -> redirect to blob storage.
out=$(mvn -B dependency:get -Dartifact=ee.cyber.cdoc2:cdoc2-lib:2.0.0 2>&1)
rc=$?
echo "$out" | tail -20
[ $rc -eq 0 ] && echo "RESOLVED OK" || echo "FAILED (mvn exit $rc) -- see above"

hr "done"
