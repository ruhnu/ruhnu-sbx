# ruhnu-sbx

A [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) kit for running
Claude Code against the [ruhnu](https://github.com/ruhnu) cdoc2 forks: JDK
17/21/25, Maven, the OpenSpec CLI, an in-sandbox Docker engine, deny-by-default
egress, and GitHub Packages credentials that never enter the VM.

Each sandbox is a microVM with its own kernel, its own Docker daemon and its
own filesystem. Claude can run in auto mode inside it without reaching the
host, the internal network, or any credential beyond a read-only packages
token.

Tested on Ubuntu 24.04 with sbx v0.51.0.

## Contents

| Path | |
|---|---|
| `kit/claude-sbx.yaml` | kit descriptor (v3): capabilities, egress policy, resources |
| `kit/claude-sbx.dockerfile` | image: JDKs, Maven, OpenSpec, Maven settings |
| `kit/m2-settings.xml` | GitHub Packages auth via proxy-substituted placeholder |
| `bootstrap-ruhnu.sh` | clone the repos, wire them to a shared OpenSpec store |
| `verify-kit.sh` | post-build checks, ending in a real artifact resolution |
| `sbx-probe.sh` | environment probe for a stock sandbox |
| `docs/findings.md` | measured sbx behaviour, including where the docs are wrong |
| `docs/openspec-multirepo.md` | verified multi-repo OpenSpec store recipe |

Changing anything in `kit/` means rebuilding the image; the scripts at the root
run inside a sandbox and take effect immediately.

## 1. Host prerequisites

```bash
lsb_release -d                  # Ubuntu 24.04+; derivatives are unsupported
lsmod | grep kvm && kvm-ok      # local sandboxes need KVM

curl -fsSL https://get.docker.com | sudo SBX=1 sh
sudo usermod -aG kvm $USER
```

**Log out and back in** to pick up the `kvm` group. Do *not* use `newgrp kvm`:
OpenSSH runs its `KnownHostsCommand` helper with `setresgid` back to your
passwd GID, which an unprivileged `newgrp` subshell cannot do, and `ssh
<name>.sbx` then fails with `setresgid 1000: Operation not permitted`.

```bash
sbx login                       # Docker OAuth; required
sbx setup ssh                   # writes a managed block to ~/.ssh/config
```

`sbx setup ssh` works on Linux, which the Docker docs do not state. No sshd
runs inside the sandbox — SSH terminates at the daemon over a unix socket, and
access is gated on your Docker login rather than an SSH key.

## 2. Secrets

Two separate credentials, both of which stay **on the host**. The sandbox only
ever sees placeholders; the host-side proxy substitutes the real values into
outbound requests.

### 2.1 `MAVEN_GH_TOKEN`

cdoc2 does not resolve entirely from Maven Central. `cdoc2-lib`,
`cdoc2-client`, `cdoc2-schema` and the openapi specifications are published to
the **GitHub Packages Maven registry** (`maven.pkg.github.com`), under the
`open-eid` organization upstream and `ruhnu` for the forks. GitHub indexes
packages per organization, so one repository URL per org resolves all of that
org's `cdoc2-*` artifacts.

That registry requires a token for **every** download, including public
packages — unlike Maven Central, which needs none. So a build cannot start
without one, and this is the token the sandbox needs.

Inside the sandbox it appears as `$MAVEN_GH_TOKEN`, holding a placeholder;
`kit/m2-settings.xml` passes that to Maven and the host-side proxy swaps in the
real value on the way out.

Create a **classic** personal access token at
github.com → Settings → Developer settings → Personal access tokens (classic):

- Scope: **`read:packages`** and nothing else.
- Set an expiry.
- Name it something revocable-at-a-glance, e.g. `sbx-github-packages-read`.

Classic, not fine-grained: GitHub Packages
[does not accept fine-grained tokens](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-apache-maven-registry).
And a token is required even to download **public** packages, unlike Maven
Central.

`read:packages` alone can download packages and do nothing else — no repo
read, no write, no acting as you. That narrowness is the entire mitigation for
running an agent in auto mode, so resist widening it. If you later want `gh` to
do more, scope a second token to one sandbox with `--sandbox` rather than
widening the global one.

Keep it out of shell history and the process list — `--value`/`--token` expose
it in both:

```bash
install -m 600 /dev/null ~/.config/gh-packages-read
# paste the token into that file
```

`~/.config` is outside every sandbox mount. **Never** put it in a project
directory: `sbx secret` helpers and the files they read must stay outside
writable sandbox mounts.

### 2.2 Register it

```bash
# For gh and api.github.com (built-in service secret)
sbx secret set github --command '/bin/cat /home/<you>/.config/gh-packages-read'

# For Maven. The built-in github secret does NOT cover maven.pkg.github.com,
# so bind an explicit custom secret to that host.
printf '%s' "$(cat ~/.config/gh-packages-read)" | sbx secret set-custom \
  --host maven.pkg.github.com --env MAVEN_GH_TOKEN --value-stdin
```

The second command prints a generated placeholder such as
`sbx-cs-lcSgZJEuHomcYyA9`. That string — not the token — is what
`$MAVEN_GH_TOKEN` holds inside the sandbox.

`set-custom` is marked experimental; it may move between sbx releases.

Why two: the built-in `github` secret substitutes for `api.github.com` but
returns 401 for `maven.pkg.github.com`. And because substitution is a literal
string match on request headers, `kit/m2-settings.xml` sends
`Authorization: Bearer ${env.MAVEN_GH_TOKEN}` via `<httpHeaders>` rather than
Maven's default Basic auth, which would base64-encode the placeholder out of
recognition. See `docs/findings.md`.

### 2.3 Claude

Run `/login` inside the sandbox. The session token stays on the host.

### 2.4 Verify

```bash
sbx secret ls
ssh ruhnu.sbx 'echo $GH_TOKEN; echo $MAVEN_GH_TOKEN'   # placeholders, not tokens
```

## 3. Egress policy

Sandboxes are deny-by-default. The Balanced preset already allows Maven
Central, GitHub, GitHub Packages and ghcr.io. One rule has to be added by hand,
because the kit's install phase fetches the OpenSpec installer:

```bash
sbx policy allow network openspec.dev
sbx policy ls
```

Everything else the build needs is declared in `kit/claude-sbx.yaml`, so the kit
also works under the Locked Down preset.

## 4. Build and create

```bash
docker buildx build -f kit/claude-sbx.yaml -t claude-sbx:dev kit/
sbx create --name ruhnu ./kit/
```

No workspace path, so the sandbox is mountless and everything lives on the VM's
own ext4 — native build speed. A host directory would reach the VM only over
virtiofs, which is markedly slower for Maven's many small reads.

The sandbox is capped at 8 CPU / 8 GiB by `resources@1`; a stock sandbox
otherwise takes the whole machine. Override per sandbox with `--cpus` /
`--memory`.

```bash
scp verify-kit.sh ruhnu.sbx:/tmp/ && ssh ruhnu.sbx 'bash /tmp/verify-kit.sh'
```

The last check resolves a real cdoc2 artifact from GitHub Packages, exercising
the whole credential path.

### Mounting a host directory

Anything not in git — scratch data, test fixtures, documents — can be shared
in from the host as an extra workspace. Workspaces are positional arguments to
`sbx create`:

```bash
sbx create --name ruhnu ./kit/                      # mountless (the default here)
sbx create --name ruhnu ./kit/ ~/data               # mounted at the same absolute path
sbx create --name ruhnu ./kit/ ~/data:/home/agent/data   # at a chosen path
sbx create --name ruhnu ./kit/ ~/data:ro            # read-only
sbx create --name ruhnu ./kit/ ~/a ~/b              # several
```

With no target the host path is mounted at **the same absolute path** inside
the sandbox, which keeps paths in logs, stack traces and workspace files valid
on both sides. Combining a custom target with `:ro` is not documented — verify
it took effect rather than assuming.

Four things to know:

**Mounts are fixed at creation.** There is no way to add one to a running
sandbox, and `sbx rm` to recreate discards the repos, `~/.m2` and anything
built locally. Take a template snapshot first (see *Lifecycle*), or plan the
mounts before building anything expensive.

**Mounted directories are virtiofs, not the VM's ext4.** A microVM has its own
kernel and cannot reach the host's filesystem directly, so everything crosses a
passthrough layer. For workloads doing many small reads — Maven resolving a
dependency tree, a Gradle daemon watching files — this is markedly slower than
VM-local storage. That is why the repos and `~/.m2` live inside the sandbox
here and only genuinely host-resident data should be mounted.

**Prefer `:ro`.** A read-write mount is the one place an agent in auto mode can
destroy something with no git history to recover from. If Claude only needs to
read the directory, say so in the mount.

**Ownership lines up by coincidence.** The sandbox user is `agent`, uid 1000;
if your host user is also uid 1000, files written in a mount appear owned by
you. Check with `touch` before relying on it.

Mounted workspaces are *not* captured by `sbx template save`, and they survive
`sbx rm` — they are on the host.

### Getting a shell

```bash
ssh ruhnu.sbx                                    # interactive shell
ssh ruhnu.sbx 'cd ~/workspace/cdoc2-lib && ls'   # one-off command
sbx run --name ruhnu                             # attach the agent, not a shell
sbx ls                                           # is it running?
sbx start ruhnu                                  # if stopped
```

Do not paste a multi-line block whose first line is a bare `ssh ruhnu.sbx` —
the following lines are swallowed by ssh's stdin before the remote shell is
ready. Connect first and then paste, or send the whole thing as
`ssh ruhnu.sbx '...'`.

## 5. Clone the repos and the OpenSpec store

```bash
scp bootstrap-ruhnu.sh ruhnu.sbx:/tmp/ && ssh ruhnu.sbx 'bash /tmp/bootstrap-ruhnu.sh'
```

Produces, inside the sandbox:

```
~/workspace/
├── cdoc2-openapi/        ├── cdoc2-shares-server/
├── cdoc2-auth/           ├── .github/           <- org profile page
├── cdoc2-java-ref-impl/  └── ruhnu-openspec/    <- OpenSpec store, id `ruhnu`
```

The four cdoc2 forks track `develop`; `.github` tracks `main`. GitHub reports
`cdoc2-auth`'s default branch as `master`, but that is stale — it sits at 0.3.3
while cdoc2-lib expects 0.7.3 — so the script clones `develop` explicitly.

`.github` is cloned but not wired to OpenSpec: it holds the org profile page
and does not want `.claude/` skills committed into it.

One store, shared by all four repos, so a change spanning the API spec and its
consumers is one OpenSpec change rather than four. Restart Claude Code before
the `/opsx:*` commands appear. See `docs/openspec-multirepo.md` for why the repos
must not keep their own `openspec/specs` and `openspec/changes` directories.

### Build order: cdoc2-openapi and cdoc2-auth first

**These two must be built from source before anything else.**
`cdoc2-java-ref-impl` needs `cdoc2-key-capsules-openapi` **3.1.2** and
`cdoc2-auth` **0.7.3**, and neither version is published to GitHub Packages
yet — not under `ruhnu`, not under `open-eid`. Building them locally puts them
in `~/.m2`, where the rest of the reactor finds them.

```bash
ssh ruhnu.sbx
cd ~/workspace/cdoc2-openapi    && ./mvnw clean install
cd ~/workspace/cdoc2-auth       && ./mvnw clean install
cd ~/workspace/cdoc2-java-ref-impl && ./mvnw clean install
```

Skipping this gives:

```
Could not find artifact ee.cyber.cdoc2.openapi:cdoc2-key-capsules-openapi:yaml:3.1.2
```

which names only Maven Central and so reads as a network or credential
problem. It is neither — the artifact does not exist in any repository yet.

This is also why `~/.m2` is worth preserving: see *Lifecycle* below. Removing
the sandbox discards these locally built artifacts along with everything else.

## 6. VS Code

All repos plus the OpenSpec store in one window — `bootstrap-ruhnu.sh` writes
the multi-root workspace file, so this just opens it:

```bash
code --file-uri "vscode-remote://ssh-remote+ruhnu.sbx/home/agent/workspace/ruhnu.code-workspace"
```

Note **`--file-uri`**, not `--folder-uri`: a `.code-workspace` is a file.
Pointing `--folder-uri` at a single repo opens only that repo, and pointing it
at `~/workspace` opens one root containing everything, which works but gives
the Java tooling a worse view of the projects.

A single repo, when that is what you want:

```bash
code --folder-uri "vscode-remote://ssh-remote+ruhnu.sbx/home/agent/workspace/cdoc2-java-ref-impl"
```

Needs the Remote-SSH extension on the host; the first connect installs the VS
Code server inside the sandbox. The editor runs in the sandbox, so it reads
VM-local files — which is why nothing needs mounting from the host.

The workspace file lives inside the sandbox, at
`~/workspace/ruhnu.code-workspace`, because that is where the VS Code server
reads it from. `bootstrap-ruhnu.sh` regenerates it on every run, so edits made
to it in VS Code — added folders, workspace settings — are overwritten. Add a
folder to `REPOS` in the script instead.

A `claude` started from the integrated terminal picks up the workspace's
folders as its working directories, so all the repos are in scope without
passing `--add-dir`.

## 7. Lifecycle

**`sbx stop` / `sbx start`, not `sbx rm`.** Stop/start preserves the repos,
`~/.m2`, installed packages — everything. `sbx rm` destroys all of it, and in a
mountless sandbox that means re-cloning and re-downloading the dependency
cache.

To keep a warm `~/.m2` for future sandboxes:

```bash
sbx stop ruhnu
sbx template save ruhnu ruhnu-base:v1
sbx create --name ruhnu2 -t ruhnu-base:v1 ./kit/
```

Saved templates capture credentials written to the sandbox filesystem. Ours
holds only placeholders, so this is safe — re-check if a real token is ever
written inside.

Push to `ruhnu` before removing a sandbox. Git is the persistence mechanism
here, not the filesystem.

## 8. Known issues

**openapi 3.1.2 and auth 0.7.3 are not published.** Build `cdoc2-openapi` and
`cdoc2-auth` from source first — see *Build order* above. Not a sandbox
problem.

**`com.docker.sandbox/dockerd@1` is in the kit spec but not implemented** by
sbx v0.51.0 / sandbox-kit 3.0.0-m.11; declaring it fails kit resolution. Not
needed — the `claude-code-docker` base ships docker-ce and the engine is
reachable as `agent` without it.

**The base image already provides** JDK 17/21/25, Maven 3.9.12, `gh`,
`ripgrep`, `jq`, `node` and `python3`, so most of the Dockerfile's apt layer is
redundant and could be dropped to speed up kit builds.

**The VM's writable overlay is 20 GB** and undocumented. A full cdoc2 build
with a cold cache uses about 190 MB, so this is ample — but it is the limit for
repos, `~/.m2` and any Testcontainers images combined.
