# TODO

## Preserve Claude sessions across `sbx rm`

Sessions live in `/home/agent/.claude/projects/<encoded-cwd>/*.jsonl` inside the
sandbox. They survive `sbx stop`/`start` and are destroyed by `sbx rm`, so a
kit change loses the history — including anything worth resuming with
`claude --resume`.

**Done** — the first option works. `create-sandbox.sh` mounts
`~/.local/share/ruhnu-sbx/claude-projects` at `/home/agent/.claude/projects`:
a directory of its own, not the host's `~/.claude/projects`, so only this
sandbox's transcripts cross and only outward. Verified 2026-11-07 on a fresh
sandbox — the mount hides no siblings, `agent` can write it, and sessions land
on the host. See `docs/findings.md`; `verify-kit.sh` rechecks it.

Still open: whether appending to a live `.jsonl` over virtiofs is ever felt in
practice. Untimed. If it is, restore from a mounted archive with a
`lifecycle@1` startup hook instead.

## Confirm the build order is mandatory, not advisory

`bootstrap-ruhnu.sh` ends by saying to `mvn install` `cdoc2-openapi` and
`cdoc2-auth` before the rest. Benchmarking turned that into a hard failure:
a build against an empty local repository cannot resolve either, in the
sandbox or out of it. Either the fork artifacts are not published to the ruhnu
GitHub Packages org, or the versions the poms want are not there. Check which,
and if they genuinely have to be built locally, say so in the README rather
than leaving it as a closing note.

## Decide whether to keep the threatmodel plugin

[josemlopez/claude-threatmodel](https://github.com/josemlopez/claude-threatmodel)
was installed by hand on 2026-11-07, at user scope, for evaluation. Reviewed
at commit `503f02a`: three prompt-only skills (`/threatmodel:quick`, `full`,
`status`) and one hook that, after every approved plan, tells Claude to run
`/threatmodel:quick` in a subagent. Nothing in it runs code by itself.

It lives in `~/.claude/plugins` on the sandbox overlay, so `sbx rm` removes
it. `/.threatmodel/`, where `full` writes its results, is excluded by hand in
the four forks' `.git/info/exclude`; the bootstrap does not do that yet.

Evaluate on real work, then decide:

- Do `quick` and `full` find anything a plain review would not, on cdoc2
  code? The quick scan is a handful of greps aimed at web apps.
- Is the per-plan subagent run worth its time and tokens, or would running
  the skills on demand be enough?

If it stays:

- Install it from the kit or the bootstrap rather than by hand, pinned to a
  reviewed commit, or forked into the ruhnu org: the marketplace tracks the
  author's `main`, so an update could change the hook unreviewed.
- Add `/.threatmodel/` to the exclude list in `bootstrap-ruhnu.sh`.
- Never run its `hooks/install-hooks.sh`: it replaces every hook in
  `~/.claude/settings.json` and installs scripts that start a nested `claude`.

If it goes: `claude plugin uninstall threatmodel@josemlopez`, remove the
`josemlopez` marketplace, and drop `/.threatmodel/` from the forks' exclude
files.

## Try mounting CLAUDE.md read-only instead of copying it

`create-sandbox.sh` copies `~/.claude/CLAUDE.md` in with `scp`. sbx v0.51.0
can mount a single file, but only read-only:

```bash
~/.claude/CLAUDE.md:/home/agent/.claude/CLAUDE.md:ro
```

That would keep it in sync with the host, stop the agent changing it, and
survive `sbx rm` without being copied in again. On a throwaway sandbox, check:

- `CLAUDE.md` and the mounted `projects/` both appear in `~/.claude`, and
  neither mount hides the other or `.credentials.json`.
- Writing to it fails inside the sandbox.
- An edit on the host shows up inside without a restart. With a file mount
  this may not happen if the editor replaces the file rather than writing in
  place.
- Claude Code actually loads it.

If all of that holds, swap the `scp` step in `create-sandbox.sh` for the
mount and update the README's *Your CLAUDE.md* section.

## Smaller items

- Drop the apt layer from the kit if the base's JDK 17/21/25 and Maven 3.9.12
  suffice — it adds ~33s to every kit build. Only `haveged` is clearly needed.
- Confirm `sbx template save` syntax by running it; the README section is
  written from the docs.
- Decide whether `ruhnu-sbx` should be wired to the OpenSpec store like the
  cdoc2 repos, or stay tooling.
