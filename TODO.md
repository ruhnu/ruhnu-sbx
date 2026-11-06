# TODO

## Preserve Claude sessions across `sbx rm`

Sessions live in `/home/agent/.claude/projects/<encoded-cwd>/*.jsonl` inside the
sandbox. They survive `sbx stop`/`start` and are destroyed by `sbx rm`, so a
kit change loses the history — including anything worth resuming with
`claude --resume`.

Options, roughly in order of preference:

- **Mount a host directory at `/home/agent/.claude/projects`.** Only this
  sandbox's own transcripts would reach the host; nothing flows the other way,
  unlike mounting all of `~/.claude` (see the README for why that is not done).
  Needs checking: whether mounting a subdirectory of `~/.claude` hides
  `CLAUDE.md` and `.credentials.json` the way mounting `~/.m2` would hide
  `settings.xml` — it should not, since those are siblings, but verify.
- **A `lifecycle@1` startup hook** that restores from a mounted archive, if a
  direct mount turns out to interact badly with how Claude Code writes session
  files.
- **Accept the loss** and copy out on demand:
  `ssh ruhnu.sbx 'tar cf - -C /home/agent .claude/projects' > sessions.tgz`

Open question either way: session paths are keyed by working directory, so
transcripts recorded in the sandbox resume only from the same absolute path.
That holds while the repos stay at `/home/agent/workspace/...`.

## Smaller items

- Drop the apt layer from the kit if the base's JDK 17/21/25 and Maven 3.9.12
  suffice — it adds ~33s to every kit build. Only `haveged` is clearly needed.
- Push this repo so `bootstrap-ruhnu.sh` can stop warning about it and fresh
  sandboxes are self-sufficient.
- Confirm `sbx template save` syntax by running it; the README section is
  written from the docs.
- Decide whether `ruhnu-sbx` should be wired to the OpenSpec store like the
  cdoc2 repos, or stay tooling.
