# ruhnu-sbx

A [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) kit for running
Claude Code against the [ruhnu](https://github.com/ruhnu) cdoc2 forks: JDK
17/21/25, Maven, the OpenSpec CLI, an in-sandbox Docker engine, deny-by-default
egress, and GitHub Packages credentials that never enter the VM.

Each sandbox is a microVM with its own kernel, its own Docker daemon and its
own filesystem. Claude can run in auto mode inside it without reaching the
host, the internal network, or any credential beyond a read-only packages
token and a push token limited to the ruhnu organization.

Tested on Ubuntu 24.04 with sbx v0.51.0.

## Contents

| Path | |
|---|---|
| `kit/claude-sbx.yaml` | kit descriptor (v3): capabilities, egress policy, resources |
| `kit/claude-sbx.dockerfile` | image: JDKs, Maven, OpenSpec, Maven settings |
| `kit/m2-settings.xml` | GitHub Packages auth via proxy-substituted placeholder |
| `create-sandbox.sh` | **host-side:** create the sandbox, seed it, bootstrap it |
| `run-sandbox.sh` | **host-side:** start it and open VS Code (or a shell) |
| `in-sandbox/bootstrap-ruhnu.sh` | clone the repos, wire them to a shared OpenSpec store |
| `in-sandbox/verify-kit.sh` | post-build checks, ending in a real artifact resolution |
| `in-sandbox/sbx-probe.sh` | environment probe for a stock sandbox |
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
read, no write, no acting as you. Keep it that way: pushing goes through the
separate token in 2.2, not through this one.

Keep it out of shell history and the process list — `--value`/`--token` expose
it in both:

```bash
install -m 600 /dev/null ~/.config/gh-packages-read
# paste the token into that file
```

`~/.config` is outside every sandbox mount. **Never** put it in a project
directory: `sbx secret` helpers and the files they read must stay outside
writable sandbox mounts.

### 2.2 `GH_TOKEN`

This is the token for `gh` and `git push`. The stock image sets `$GH_TOKEN` to
the sentinel `gho_sbxproxymanaged000000000000000000000`, and the proxy
substitutes the token registered as the built-in `github` secret on requests to
`github.com` and `api.github.com`. It does so on **every** request, even one
that carries no credentials, so `git push` over https needs no credential
helper inside the sandbox.

Because the proxy authenticates everything, this token decides what the agent
can do on GitHub. Make it a **fine-grained** token owned by the ruhnu
organization, so it cannot write to your personal account or any other org.
Create it in your own settings, not the org's — github.com → Settings →
Developer settings → Personal access tokens → **Fine-grained tokens**
(<https://github.com/settings/personal-access-tokens/new>):

- **Resource owner: `ruhnu`.** If ruhnu is missing from the list, an org owner
  has to allow fine-grained tokens first: org Settings → Third-party Access →
  Personal access tokens → Settings. If the org requires approval, the token
  only works once an owner approves it under "Pending requests".
- **Repository access:** all repositories, or only the ones the sandbox should
  push to.
- **Repository permissions:** Contents: **Read and write**; Metadata:
  Read-only is added automatically. Nothing else, and no organization
  permissions.
- Set an expiry, and name it e.g. `sbx-ruhnu-push`.

What it still allows: pushing to any branch of the selected repos, including
force-push and branch deletion. Protect `master`, `main` and `develop` with a
ruleset that blocks force-push and deletion — that is the limit on what an
agent can do with this token.

Left out on purpose:

- **Pull requests.** Pull requests: Read and write would let the agent comment
  on, close and approve other people's PRs in your name. Open PRs from the host
  or the web UI; the permission can be added to the existing token later.
- **Packages.** GitHub Packages does not accept fine-grained tokens, and a
  classic `write:packages` token cannot be limited to one org. Publish Maven
  packages and images from GitHub Actions with `GITHUB_TOKEN` instead, or from
  a machine user that belongs only to ruhnu.

```bash
install -m 600 /dev/null ~/.config/gh-ruhnu-push
# paste the token into that file
```

### 2.3 Register them

```bash
# For gh, git push, github.com and api.github.com (built-in service secret)
sbx secret set github --command '/bin/cat /home/<you>/.config/gh-ruhnu-push'

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
returns 401 for `maven.pkg.github.com`, and the push token could not authorize
Maven downloads anyway, because the registry accepts only classic tokens. And
because substitution is a literal string match on request headers,
`kit/m2-settings.xml` sends `Authorization: Bearer ${env.MAVEN_GH_TOKEN}` via
`<httpHeaders>` rather than Maven's default Basic auth, which would
base64-encode the placeholder out of recognition. See `docs/findings.md`.

### 2.4 Claude

Run `/login` inside the sandbox. The session token stays on the host.

### 2.5 Verify

```bash
sbx secret ls
ssh ruhnu.sbx 'echo $GH_TOKEN; echo $MAVEN_GH_TOKEN'   # placeholders, not tokens
```

Inside the sandbox, check that the push token reaches ruhnu and nothing else.
The `git-receive-pack` endpoint answers 200 where you can push and 403 where
you cannot:

```bash
probe() { curl -s -o /dev/null -w "$1: %{http_code}\n" \
  "https://github.com/$1.git/info/refs?service=git-receive-pack"; }
probe ruhnu/ruhnu-sbx          # 200
probe <you>/<personal-repo>    # 403
```

`gh auth status` reports `Token scopes: none` for a fine-grained token. That is
expected and does not mean it lacks permissions.

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
./create-sandbox.sh                      # or: ./create-sandbox.sh <name>
```

`create-sandbox.sh` runs on the **host** — unlike the other scripts here, which
run inside a sandbox. It creates the sandbox with the mounts below, copies your
`~/.claude/CLAUDE.md` in, and runs the bootstrap. Equivalent to:

```bash
DATA=~/workspace/ruhnu-workspace
mkdir -p "$DATA" ~/.m2/repository ~/.local/share/ruhnu-sbx/claude-projects
sbx create --name ruhnu ./kit/ \
  "$DATA" \
  ~/.m2/repository:/home/agent/.m2/repository \
  ~/.local/share/ruhnu-sbx/claude-projects:/home/agent/.claude/projects
ssh ruhnu.sbx 'mkdir -p ~/.claude'
scp ~/.claude/CLAUDE.md ruhnu.sbx:/home/agent/.claude/CLAUDE.md
ssh ruhnu.sbx "RUHNU_DATA_DIR=$DATA bash $DATA/ruhnu-sbx/in-sandbox/bootstrap-ruhnu.sh"
```

Giving:

```
/home/<you>/workspace/ruhnu-workspace/  mounted, at its host path:
    cdoc2-openapi/  cdoc2-auth/  cdoc2-java-ref-impl/  cdoc2-shares-server/
    .github/  ruhnu-openspec/        cloned by the bootstrap
    cdoc2-ssh/  ruhnu-sbx/           copied in by you
    ruhnu.code-workspace             written by the bootstrap
/home/agent/.m2/repository/             mounted: the dependency cache
/home/agent/.claude/projects/           mounted: Claude's session transcripts
```

**One directory holds everything you work on**, mounted at its host path, so
every repo has a single absolute path valid on both sides. `ssh`, the VS Code
workspace file, stack traces and Claude's cwd-keyed transcripts all agree, and
nothing is lost to `sbx rm`. Choose it with `--data-dir` or `RUHNU_DATA_DIR`;
the default is `~/workspace/ruhnu-workspace`.

This is only tenable because virtiofs costs nothing measurable here — see
*Measured: mounting ~/.m2 over virtiofs costs nothing here* in `docs/findings.md`.
The caveat in that section applies: a *cold* Maven resolve, which writes
thousands of small files, was never measured. If a build ever feels slow, that
is the first thing to suspect.

It also means an agent in auto mode is writing to host-resident repos with no
VM boundary behind them. They have remotes; commit often.

The two remaining mounts:

**`~/.m2/repository`**, so the dependency cache survives `sbx rm`. That is 293
MB of re-download every time the kit changes. Mounting it was measured at no
cost for this project (15s VM-local vs 15s mounted, warm offline build); see
`docs/findings.md`. Mount the `repository` subdirectory, not `~/.m2` — the kit
bakes `settings.xml` into `~/.m2/` and mounting the parent would hide it.

**`~/.claude/projects`**, so Claude's session transcripts survive `sbx rm` and
`claude --resume` still finds them after a kit change. The host side is
`~/.local/share/ruhnu-sbx/claude-projects`, a directory of its own — *not* the
host's `~/.claude/projects`, which holds transcripts for every repo you have
ever opened. Only this sandbox's own history crosses, and only outward. Set
`RUHNU_CLAUDE_PROJECTS_DIR` to put it elsewhere — a second sandbox wanting its
own history, say:

```bash
RUHNU_CLAUDE_PROJECTS_DIR=~/.local/share/ruhnu-sbx/claude-projects-two \
  ./create-sandbox.sh ruhnu2
```

Transcripts are keyed by working directory. Now that the repos sit at one path
on both sides, a transcript recorded in the sandbox also resumes on the host.

### What goes in the data directory

The bootstrap clones the four cdoc2 forks, `.github` and the OpenSpec store
into it, skipping any that are already there — so it is safe to re-run, and
safe to put repos there yourself first.

Two you have to put there by hand:

- **`cdoc2-ssh`**, which lives on `gitlab.cyber.ee` over SSH. The sandbox has
  no key for it and internal hosts are not in the egress policy.
- **`ruhnu-sbx`** — this repo. The bootstrap runs from it, so it has to exist
  before the sandbox does: clone it on the host (see section 5). If you leave
  it outside the data directory, `create-sandbox.sh` mounts it separately,
  also at its host path, and everything still works.

Anything else you copy in is picked up too: the workspace file lists every
directory it finds, not a hardcoded set.

The data directory takes the first positional slot in `sbx create`, because the
*primary* workspace must mount at its host path — `HOST:TARGET` is rejected for
it and accepted only for the paths after. That is also what you land in on
`ssh ruhnu.sbx`.

The sandbox is capped at 8 CPU / 8 GiB by `resources@1`; a stock sandbox
otherwise takes the whole machine. Override per sandbox with `--cpus` /
`--memory`.

```bash
ssh ruhnu.sbx "bash $DATA/ruhnu-sbx/in-sandbox/verify-kit.sh"
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

### Your CLAUDE.md

`create-sandbox.sh` copies it in; by hand it is:

```bash
ssh ruhnu.sbx 'mkdir -p ~/.claude'
scp ~/.claude/CLAUDE.md ruhnu.sbx:/home/agent/.claude/CLAUDE.md
```

Copied rather than mounted: sbx mounts directories, not single files.

**The host's `~/.claude` is deliberately not mounted.** It holds
`.credentials.json` (a live OAuth token), `.claude.json` (every project you
have opened, plus MCP config that often carries tokens) and `projects/` — full
session transcripts for every repo you have ever worked in. Mounting it
read-write would hand all of that to an agent running in auto mode, and would
undo the credential isolation the rest of this setup is built on. The sandbox's
own `~/.claude/projects` is a mount, but from a separate host directory holding
nothing but this sandbox's transcripts; the rest of `~/.claude` stays VM-local,
so `/login` writes its token inside the sandbox and nowhere else.

Authentication does not need it: run `/login` inside the sandbox and the
session token stays on the host.

Re-copy after `sbx rm`, and run `/login` again — the token is VM-local and goes
with the sandbox, deliberately. Only `projects/` is mounted, so the transcripts
come back on their own. Both survive `sbx stop`/`start`.

### Getting a shell

```bash
ssh ruhnu.sbx                                    # interactive shell
ssh ruhnu.sbx 'cd $DATA/cdoc2-lib && ls'         # one-off command
sbx run --name ruhnu                             # attach the agent, not a shell
sbx ls                                           # is it running?
sbx start ruhnu                                  # if stopped
```

Do not paste a multi-line block whose first line is a bare `ssh ruhnu.sbx` —
the following lines are swallowed by ssh's stdin before the remote shell is
ready. Connect first and then paste, or send the whole thing as
`ssh ruhnu.sbx '...'`.

## 5. Clone the repos and the OpenSpec store

`create-sandbox.sh` runs this for you. By hand, from the data directory, which
has the same path on both sides:

```bash
DATA=~/workspace/ruhnu-workspace
ssh ruhnu.sbx "RUHNU_DATA_DIR=$DATA bash $DATA/ruhnu-sbx/in-sandbox/bootstrap-ruhnu.sh"
ssh ruhnu.sbx "bash $DATA/ruhnu-sbx/in-sandbox/verify-kit.sh"
```

Re-runnable: repos already cloned are skipped, so it is also how you add the
ones that are missing after copying something in by hand.

Claude inside the sandbox can then read `docs/` and run or edit these scripts
directly. One thing it cannot do: rebuild the image it is running in.
`docker buildx build` is a host-side step, so changes under `kit/` still have
to be applied from the host.

The bootstrap does not clone this repo — it runs from it. Clone it into the
data directory host-side first; no ssh needed, since that directory is the
mount:

```bash
git clone https://github.com/ruhnu/ruhnu-sbx ~/workspace/ruhnu-workspace/ruhnu-sbx
```

The OpenSpec store is cloned from `github.com/ruhnu/ruhnu-openspec` (branch
`master`). Only if that clone fails does the bootstrap create a fresh, empty
store with the same id — which then has no history in common with the GitHub
one.

Produces, on both sides:

```
<data dir>/
├── cdoc2-openapi/        ├── .github/           <- org profile page
├── cdoc2-auth/           ├── ruhnu-sbx/         <- this repo
├── cdoc2-java-ref-impl/  └── ruhnu-openspec/    <- OpenSpec store, id `ruhnu`
├── cdoc2-shares-server/
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
cd ~/workspace/cdoc2-openapi       && mvn clean install
cd ~/workspace/cdoc2-auth          && mvn clean install
cd ~/workspace/cdoc2-java-ref-impl && ./mvnw clean install
```

Note `mvn` for the first two: only `cdoc2-java-ref-impl` ships a Maven
wrapper. The kit installs Maven 3.9.12 for exactly this.

`cdoc2-openapi`'s own pom is version 3.1.0, which looks wrong but is not: each
`*-openapi.yaml` is published as its own artifact, versioned from the `info.version`
inside it. `cdoc2-key-capsules-openapi.yaml` carries 3.1.2, which is what
`cdoc2-client` asks for.

Skipping this gives:

```
Could not find artifact ee.cyber.cdoc2.openapi:cdoc2-key-capsules-openapi:yaml:3.1.2
```

which names only Maven Central and so reads as a network or credential
problem. It is neither — the artifact does not exist in any repository yet.

This is also why `~/.m2` is worth preserving: see *Lifecycle* below. Removing
the sandbox discards these locally built artifacts along with everything else.

## 6. VS Code

```bash
./run-sandbox.sh                 # start the sandbox, open VS Code on it
./run-sandbox.sh --no-vscode     # start it and drop into a shell instead
./run-sandbox.sh myname          # a sandbox other than 'ruhnu'
./run-sandbox.sh --data-dir PATH # a data directory other than the default
```

Host-side, like `create-sandbox.sh`. It starts the sandbox if it is stopped,
then opens the multi-root workspace — all the repos plus the OpenSpec store in
one window. By hand:

```bash
code --file-uri "vscode-remote://ssh-remote+ruhnu.sbx$DATA/ruhnu.code-workspace"
```

with `DATA` as above. Note **`--file-uri`**, not `--folder-uri`: a
`.code-workspace` is a file. Pointing `--folder-uri` at a single repo opens
only that repo, and pointing it at the data directory opens one root containing
everything, which works but gives the Java tooling a worse view of the
projects.

A single repo, when that is what you want:

```bash
code --folder-uri "vscode-remote://ssh-remote+ruhnu.sbx$DATA/cdoc2-java-ref-impl"
```

Needs the Remote-SSH extension on the host; the first connect installs the VS
Code server inside the sandbox. The editor runs in the sandbox, reading the
repos through the data-directory mount — the same files your host editor would
open, at the same paths.

The **Claude Code extension is baked into the kit**, so it is present in the
sandbox from the first connect rather than being fetched from the marketplace.
Two extensions are involved and the sides matter:

| Install on | Extension | |
|---|---|---|
| host | `ms-vscode-remote.remote-ssh` | makes the connection |
| sandbox | `anthropic.claude-code` | already in the image |

A `claude` started from the integrated terminal runs inside the sandbox, under
the same egress policy and with the same placeholder credentials as everything
else.

The workspace file lives inside the sandbox, at
`~/workspace/ruhnu.code-workspace`, because that is where the VS Code server
reads it from. `in-sandbox/bootstrap-ruhnu.sh` regenerates it on every run, so edits made
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
