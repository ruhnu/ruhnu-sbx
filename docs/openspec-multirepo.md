# OpenSpec across several repos, with a shared store

Verified against OpenSpec **1.16.0** (`@fission-ai/openspec`), 2026-11-06, by
running the commands — not from the docs. Stores are a beta feature: "command
names, flags, and file formats can change between releases."

## What `openspec init --tools claude` actually writes

```
.claude/commands/opsx/{apply,archive,explore,propose,sync,update}.md
.claude/skills/openspec-{apply-change,archive-change,explore,propose,sync-specs,update-change}/SKILL.md
openspec/config.yaml
openspec/specs/.gitkeep
openspec/changes/archive/.gitkeep
```

No `CLAUDE.md`, no `AGENTS.md`, no MCP config — it only adds skills and slash
commands. Six more workflows (`new`, `continue`, `ff`, `bulk-archive`,
`verify`, `onboard`) are available via `openspec config profile`.

Claude Code must be restarted before the `/opsx:*` commands appear.

## The layout that works

One store repo holds all the planning artifacts; each code repo points at it
and keeps only the `.claude/` skills locally.

```
openspec/springplat/          <- the store: its own git repo
  .openspec-store/store.yaml
  openspec/{config.yaml,specs/,changes/archive/}
svc-a/                        <- code repo
  .claude/{skills,commands}/  <- from `openspec init --tools claude`
  openspec/config.yaml        <- ONLY this file: `store: springplat`
svc-b/                        <- same shape
```

### Three constraints the docs don't spell out

**A store cannot be created inside another git repository.** `openspec store
setup` fails with "Store setup path is inside another Git repository". Pass
`--no-init-git` to override, but the clean answer is to give the store its own
path outside every code repo.

**A code repo may not be both a real OpenSpec root and a store consumer.** If
`openspec/specs/` or `openspec/changes/` exist locally, a `store:` line in
`openspec/config.yaml` is silently ignored:

> declares store 'springplat', but this directory is a real OpenSpec root; the
> declaration is ignored

So after `openspec init`, delete the two directories it just made. That is what
makes the repo store-only.

**One checkout per store id per machine.** Re-registering the same id at a
second path errors; `openspec store unregister <id>` first.

## Recipe

```bash
# 1. the store, outside any code repo
openspec store setup springplat --path ~/openspec/springplat

# 2. each code repo
cd svc-a
openspec init --tools claude
rm -rf openspec/specs openspec/changes
printf 'schema: spec-driven\nstore: springplat\n' > openspec/config.yaml

# 3. verify
openspec doctor      # expect: Store: springplat (metadata ok)
openspec list
```

Every OpenSpec command run from either repo then resolves to the store:

```
Using OpenSpec root: springplat (~/openspec/springplat)
```

A change created from `svc-a` is immediately visible from `svc-b`. `openspec
new change <id>` scaffolds only `.openspec.yaml`; `proposal.md`, `tasks.md` and
the spec deltas are written by the agent through the skills.

## Machine-local state

Store registration lives **outside** any repo, at:

```
~/.local/share/openspec/stores/registry.yaml
~/.config/openspec/config.json          # telemetry id
```

This matters for a disposable sandbox: the registration does not travel with
the repos and has to be recreated each time the sandbox is rebuilt. Either run
`openspec store register <path>` from a lifecycle hook, or keep the sandbox
long-lived.

## Network

Core commands need no login and no API key, and store operations never touch
the network ("OpenSpec never clones, pulls, or pushes" — the store is a plain
local git repo you push yourself).

Behind a deny-by-default egress policy, allow for installation only:
`openspec.dev`, `github.com`, `registry.npmjs.org`. At runtime set
`OPENSPEC_NO_UPDATE_CHECK=1` and `DO_NOT_TRACK=1`, and leave
`edge.openspec.dev` blocked unless something actually breaks — the docs never
say what it is for, it only shows up in the Deno install line.
