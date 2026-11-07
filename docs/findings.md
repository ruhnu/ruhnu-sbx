# Docker Sandboxes (sbx): measured facts

Everything here was measured on this host with `in-sandbox/sbx-probe.sh`, 2026-11-06,
sbx **v0.51.0**, against a stock `shell` sandbox under the **Balanced** network
policy. Where the Docker docs say something different, or say nothing, that is
noted.

## Platform

Linux is supported and SSH works, which the docs never confirm. `sbx setup ssh`
reports `● enabled · signed in as <user>`, access is `*.sbx -> sandboxd.sock
(no port · login-gated)`, and `ssh <name>.sbx` lands in the sandbox. Install was
`curl -fsSL https://get.docker.com | sudo SBX=1 sh` on Ubuntu 24.04 with KVM.

**Gotcha:** do not use `newgrp kvm` to pick up the group. OpenSSH runs its
`KnownHostsCommand` helper with `setresgid` back to your passwd GID, which an
unprivileged `newgrp` subshell cannot do:

```
KnownHostsCommand-ORDER: setresgid 1000: Operation not permitted
```

Log out and back in instead.

## Inside the sandbox

Base is **Debian 13 (trixie)**, "hardened by DHI" — not Ubuntu, despite the
docs' template examples. The `shell` kit is 1.1.0.

```
uid=1000(agent) gid=1000(agent) groups=1000(agent),27(sudo),999(docker)
HOME=/home/agent
```

- **Passwordless sudo: yes.** The docs say "sudo access" but never whether a
  password is needed.
- **Docker engine: reachable as `agent` without sudo** — `agent` is in the
  `docker` group. The docs never say how the agent reaches the daemon.
- Preinstalled: `git`, `curl`, `jq`, `gh`, `rg`, `docker`.
  Missing: `java`, `mvn`, `node`, `npm`.
- **No locale is set.** `LANG` and `LC_ALL` are empty, so everything runs
  under `POSIX`, although `C.utf8` is installed. See *Locale* below.

## Locale: the JVM encodes file names as ASCII

Measured 2026-11-06 in the `claude-code-docker-0.10.0` base, JDK 21:

```
$ locale        ->  LC_CTYPE="POSIX" (LANG, LC_ALL empty)
$ locale -a     ->  C  C.utf8  POSIX
$ java -XshowSettings:properties -version
    file.encoding    = UTF-8
    native.encoding  = ANSI_X3.4-1968
    sun.jnu.encoding = ANSI_X3.4-1968
```

`file.encoding` defaults to UTF-8 since JDK 18 (JEP 400), so file *contents*
are fine. File *names* are encoded with `sun.jnu.encoding`, which still comes
from the locale. Under POSIX that is ASCII, and any non-ASCII path fails:

```
java.nio.file.InvalidPathException: Malformed input or input contains
  unmappable characters: ann‮txt.exe
```

This made `./mvnw test` fail in cdoc2-java-ref-impl:
`TarDeflateTest.shouldValidateFileNameWhenCreatingTar` creates files with
hostile names, including a U+202E right-to-left override. The test only
tolerates `InvalidPathException` on Windows. Because `cdoc2-lib` failed,
`cdoc2-cli` was skipped. With `LC_ALL=C.UTF-8` the whole reactor passes.

`-Dsun.jnu.encoding=UTF-8` is not a fix: that property is read-only and
unsupported as a command-line override. The locale has to be right.

Fix: `ENV LANG=C.UTF-8` in the kit dockerfile. `C.UTF-8` is already in the
base, so no `locales` package is needed. Use `LANG` rather than `LC_ALL`, so
individual `LC_*` can still be overridden. Image `ENV` reaches SSH and VS Code
sessions too; the base's `JAVA_TOOL_OPTIONS` arrives the same way. Until the
image is rebuilt, `export LANG=C.UTF-8` in the shell works around it.

## Filesystem

```
host      virtiofs  935G   /home/jkusman/sbx-probe   <- the mounted workspace
overlay   overlay    20G   /                          <- everything else
```

- The host workspace is mounted at **the same absolute path** as on the host,
  over **virtiofs** — the slow path.
- `$HOME` is on the overlay, which is **20 GB**. Undocumented, and a real
  constraint: under a clone-inside-the-VM strategy that 20 GB holds the cloned
  repos, `~/.m2`, and every Docker image Testcontainers pulls.
- Files the agent writes into the mounted workspace show as `agent:agent`
  inside. Host-side ownership not yet confirmed (host UID is also 1000).

## Egress under the Balanced preset

`403` is the gateway proxy denying; anything else means the host was reached.

| Host | | |
|---|---|---|
| `repo.maven.apache.org` | 200 | allowed |
| `github.com` | 200 | allowed |
| `api.github.com` | 200 | allowed |
| `maven.pkg.github.com` | 301 | allowed |
| `ghcr.io/v2/` | 401 | allowed (401 is "authenticate", not a block) |
| `registry.npmjs.org` | 200 | allowed |
| `api.anthropic.com` | 404 | allowed |
| `openspec.dev` | **403** | **denied** |
| `edge.openspec.dev` | **403** | **denied** |

So the only policy change the Spring + OpenSpec setup needs is:

```bash
sbx policy allow network openspec.dev
```

DNS resolves normally (`getent`, `nslookup`) despite UDP being blocked by
default — the resolver is on the host side of the proxy.

## Credentials: `gh` works without a token in the VM

The stock image **already sets `GH_TOKEN` to a sentinel**. With no secret
registered, `gh` reports:

```
X Failed to log in to github.com using token (GH_TOKEN)
  The token in GH_TOKEN is invalid.
```

— not "not logged in". That is the injection scheme working: `gh`'s local auth
check passes because a token is present, and the host-side proxy is meant to
substitute the real value on the way out. Register the source on the host:

```bash
sbx secret set github --command 'gh auth token'
```

The sentinel is the literal string `gho_sbxproxymanaged000000000000000000000`.
With a secret registered, `curl -H "Authorization: Bearer $GH_TOKEN"
https://api.github.com/rate_limit` returns **200** from inside the sandbox — so
the real token genuinely never enters the VM, and substitution works.

### ...but the built-in secret does not cover maven.pkg.github.com

The same sentinel against `maven.pkg.github.com` returns **401** — with Basic
*and* with Bearer — while the identical request from the host with the real
token returns 302. A 401 rather than 403 rules out the egress policy. The
built-in `github` service secret covers `api.github.com` and not the packages
registry.

This matters because **GitHub Packages' Maven registry requires a token even to
download public packages**, unlike Maven Central.

### Fix: an explicit custom secret

`sbx secret set-custom` (experimental in v0.51.0) binds a secret to hosts you
name, and restores full isolation:

```bash
printf '%s' "$(cat ~/.config/gh-packages-read)" | sbx secret set-custom \
  --host maven.pkg.github.com --env MAVEN_GH_TOKEN --value-stdin
```

It generates a placeholder (e.g. `sbx-cs-lcSgZJEuHomcYyA9`), sets
`$MAVEN_GH_TOKEN` in the sandbox to it, and the proxy swaps in the real token
on requests to that host. The real value never enters the VM.

Two details that decide the Maven config:

- Substitution is a **literal string match on request headers**. Maven's
  default Basic auth base64-encodes `user:token`, hiding the placeholder — so
  `settings.xml` must use `<httpHeaders>` with `Bearer ${env.MAVEN_GH_TOKEN}`,
  not `<username>`/`<password>`. The GitHub Packages Maven registry accepts
  Bearer (verified: 302 to blob storage).
- Bind to `maven.pkg.github.com` only. The redirect host serves signed URLs and
  clients drop `Authorization` across hosts anyway.

Use `--value-stdin`, never `--value`/`--token`, which expose the secret in
shell history and the process list. Keep the PAT classic and `read:packages`
only, with an expiry: it can download packages and nothing else.

`set-custom` is marked experimental, so this may move between releases.

`ghcr.io` public image pulls, by contrast, work anonymously from inside the
sandbox — confirmed, no credentials needed.

The redirect target for Maven artifacts is
`github-registry-files.githubusercontent.com` (measured), which must be in the
egress allowlist or downloads fail *after* a successful authentication.

The username in Basic auth is ignored when the token is valid — a literal `x`
works — so no per-user build configuration is needed.

## Defaults worth overriding

A stock sandbox was given `CPU: 24`, `Memory: 11.6 GiB` — the whole machine.
Set `resources@1` in the kit.

## Kit capabilities: the spec runs ahead of the runtime

Built with sbx v0.51.0 / sandbox-kit `3.0.0-m.11`. The descriptor decodes
strictly — an unknown field or an unimplemented capability fails the build —
and the spec documents more than this build supports.

| Capability | Result |
|---|---|
| `sbx@1` | works (config-less; any `config` is an error) |
| `resources@1` | works. Fields are `cpu` (float, singular — **not** `cpus`) and `memory` (byte-size string, `8g` — **not** `8GiB`) |
| `network-policy@1` | works. `install:` / `runtime:`, each with `allow:` / `deny:` lists |
| `long-running@1` | works (config-less) |
| `git-identity@1` | works — carries the host's git identity into the sandbox. Without it `openspec store setup` cannot make its initial commit and nothing can commit at all |
| `dockerd@1` | **"unsupported capability type"** — in the spec, not in this build. Not needed: the `claude-code-docker` base ships docker-ce and the engine is reachable as `agent` without it |

Mark anything uncertain `optional: true` so kit resolution degrades instead of
failing.

## Measured: mounting ~/.m2 over virtiofs costs nothing here

A mounted host directory reaches the VM only over virtiofs — a microVM has its
own kernel and cannot touch the host filesystem directly. On an earlier
Multipass setup a virtiofs mount measured ~90x slower than ext4 for a pnpm
install on a large monorepo, so the assumption going in was that mounting the
Maven cache would be costly.

It is not, for this workload. Same warm 293 MB cache, same repos VM-local,
`./mvnw -o -q clean install -DskipTests` on cdoc2-java-ref-impl:

| `~/.m2/repository` | run 1 | run 2 | run 3 |
|---|---|---|---|
| VM-local (overlay) | 15s | 15s | 14s |
| mounted from host (virtiofs) | 17s | 15s | 15s |

The 2s on the first mounted run is cold page cache; it disappears afterwards.

Why the difference from the pnpm case: a warm Maven cache is read-mostly and
made of jar-sized files rather than a deep tree of tiny ones and symlinks;
virtiofs caching is on by default in sbx; and this build is CPU-bound anyway —
about 37s of user time against 15s wall on 8 cores. A *cold* resolve, which
writes thousands of small metadata files, was not measured and may behave
differently.

So mount the cache. It survives `sbx rm`, which otherwise costs a 293 MB
re-download every time the kit changes:

```bash
sbx create --name ruhnu ./kit/ \
  ~/workspace/ruhnu-sbx \
  ~/.m2/repository:/home/agent/.m2/repository
```

Two constraints found while doing this:

- The **first** positional path is the primary workspace and must mount at its
  host path. `HOST:TARGET` is rejected for it ("primary workspace is mounted at
  its host path"), so a target-less primary has to come first.
- Mount `~/.m2/repository`, not `~/.m2`: the kit bakes `settings.xml` into
  `~/.m2/` and mounting the parent would hide it.

## Measured: the repos themselves cost ~5% on virtiofs

Mounting `~/.m2` was cheap, so the whole working tree moved onto a host-mounted
data directory. This is what that costs. Same sandbox, same `~/.m2` (mounted in
both arms), `cdoc2-java-ref-impl`, arms alternating so drift hits both;
`in-sandbox/bench-fs.sh` reproduces it.

Warm offline `clean install -DskipTests`:

| source tree on | run 1 | run 2 | run 3 |
|---|---|---|---|
| virtiofs (data dir) | 15.30s | 15.88s | 15.28s |
| ext4 (VM overlay) | 14.52s | 14.83s | 14.96s |

About 0.8s, or 5%. Consistent in direction, negligible in size — the build is
CPU-bound, as the `~/.m2` measurement found.

Metadata operations are where virtiofs is genuinely slower. Copying the
dependency cache (308 MB, 5157 files) onto each filesystem, then traversing and
deleting it:

| operation | virtiofs | ext4 | ratio |
|---|---|---|---|
| copy in | 2.55s | 1.56s | 1.6x |
| stat every file | 0.161s | 0.033s | 4.9x |
| delete | 0.341s | 0.106s | 3.2x |

So the 3-5x penalty on per-file operations is real, and at this scale it is
still milliseconds: ~130ms extra to stat 5000 files. `git status` on the repo
was 7-15ms either way, which is noise. A cold resolve writing a few thousand
artifacts should cost on the order of a second extra, not the ~90x seen on a
pnpm monorepo over virtiofs elsewhere.

Caveats: nothing dropped the page cache, so the traversal ran warm in both
arms; and the first attempt at a cold-resolve arm failed in *both* arms —
building against an empty local repository cannot resolve `cdoc2-openapi` and
`cdoc2-auth`, which is a build-order fact about the repos, not a filesystem
result.

Conclusion: keep the working tree in the data directory. The 5% buys one path
per repo on both sides, and survival across `sbx rm`.

## Measured: mounting `~/.claude/projects` preserves sessions, and hides nothing

Claude's session transcripts live in `~/.claude/projects/<encoded-cwd>/*.jsonl`
and are destroyed by `sbx rm`, taking with them anything worth resuming with
`claude --resume`. Mounting a host directory over that one subdirectory keeps
them, without exposing the rest of `~/.claude` in either direction:

```bash
sbx create --name ruhnu ./kit/ ... \
  ~/.local/share/ruhnu-sbx/claude-projects:/home/agent/.claude/projects
```

The worry was that mounting a subdirectory would hide its siblings, the way
mounting `~/.m2` would hide `settings.xml`. It does not — the mount lands on
`projects/` alone. Verified 2026-11-07 after a fresh `create-sandbox.sh`:

```
drwxrwxr-x 3 agent agent 4096 projects         <- virtiofs, rw, writable by agent
-rw------- 1 agent agent  551 .credentials.json  <- still there, VM-local
-rw------- 1 agent agent  312 history.jsonl
```

So `/login` still writes its token inside the VM and nowhere else, and
`CLAUDE.md` copied in afterwards stays put. `findmnt` reports
`host[/home/jkusman/.local/share/ruhnu-sbx/claude-projects] virtiofs rw`, the
mount point is writable by `agent` (uid 1000 on both sides), and a session
recorded in the sandbox appeared on the host as
`claude-projects/-home-agent-workspace/`.

Transcripts are keyed by working directory, so they resume only from the same
absolute path. Since the repos live in the data directory, which mounts at its
host path, that path is the same on both sides — a transcript recorded in the
sandbox resumes on the host too.

Unlike the Maven cache, this was not timed. Claude appends to the live
transcript continuously; if virtiofs ever makes that felt, the fallback is a
`lifecycle@1` hook restoring from a mounted archive at start.

## Base image

There is no `docker/sandbox-templates:claude`. Tags are
`<agent>[-docker][-<version>]`, e.g. `claude-code-docker-0.10.0`; the `-docker`
flavour ships the in-sandbox engine. Pin the version — the bare tag moves.

That base already provides JDK 17, 21 **and** 25, Maven 3.9.12, `gh`,
`ripgrep`, `jq`, `node`, `python3` and docker-ce, so most of a Java kit's apt
layer is redundant. It also presets `JAVA_TOOL_OPTIONS` to route Java through
`gateway.docker.internal:3128`, which is why Maven reaches the egress proxy
with no extra configuration.
