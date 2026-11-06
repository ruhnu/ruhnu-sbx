#!/bin/bash
# Run INSIDE a Docker sandbox (ssh probe.sbx), then paste the output back.
# Answers the questions the sbx docs leave open, for the Spring/OpenSpec trial.
# Nothing here changes host state. Read-only except for one touch in the mount.

hr() { printf '\n=== %s\n' "$1"; }

hr "identity"
id
echo "HOME=$HOME  PWD=$PWD"

hr "sudo (passwordless?)"
sudo -n true 2>&1 && echo "YES: passwordless sudo" || echo "NO: sudo wants a password"

hr "docker engine, as the agent user"
groups
docker info 2>&1 | head -5
docker ps 2>&1 | head -2

hr "toolchain present in the shell image"
for t in git curl jq node npm java mvn gh docker rg; do
    printf '%-6s %s\n' "$t" "$(command -v $t || echo '-- missing')"
done

hr "mounted workspace, ownership"
# The sandbox was created with '.' as the workspace, mounted at the same
# absolute path. Write a file and check who owns it from the HOST afterwards.
ls -ld . 2>&1
touch ./sbx-probe-ownership.txt 2>&1 && ls -l ./sbx-probe-ownership.txt \
    || echo "could not write to the mounted workspace"

hr "filesystem: is the mount virtiofs, and is \$HOME local?"
mount | grep -Ei 'virtiofs|9p|ext4|overlay' | head -10
df -hT . "$HOME" 2>&1

hr "egress under the default policy"
for url in https://api.anthropic.com \
           https://repo.maven.apache.org/maven2/ \
           https://github.com \
           https://api.github.com \
           https://maven.pkg.github.com \
           https://ghcr.io/v2/ \
           https://registry.npmjs.org \
           https://openspec.dev \
           https://edge.openspec.dev; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$url" 2>&1)
    printf '%-42s %s\n' "$url" "${code:-FAILED}"
done

hr "DNS / UDP (docs say UDP is blocked by default)"
getent hosts github.com || echo "getent failed"
timeout 5 nslookup github.com 2>&1 | tail -3

hr "gh cli auth, if gh exists"
if command -v gh > /dev/null; then
    gh auth status 2>&1 | head -10
    echo "--- does an unauthenticated API call work (proxy header injection?)"
    gh api rate_limit 2>&1 | head -5
else
    echo "gh not installed in this image -- it goes in the kit"
fi

hr "ghcr anonymous pull of a public image"
timeout 90 docker pull ghcr.io/distroless/static:latest 2>&1 | tail -3

hr "done"
