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

## Smaller items

- Drop the apt layer from the kit if the base's JDK 17/21/25 and Maven 3.9.12
  suffice — it adds ~33s to every kit build. Only `haveged` is clearly needed.
- Push this repo so `bootstrap-ruhnu.sh` can stop warning about it and fresh
  sandboxes are self-sufficient.
- Confirm `sbx template save` syntax by running it; the README section is
  written from the docs.
- Decide whether `ruhnu-sbx` should be wired to the OpenSpec store like the
  cdoc2 repos, or stay tooling.
