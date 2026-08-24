# claude-cloud-env

Operational scripts fetched by every [Claude Code cloud environment](https://code.claude.com)
web-UI setup script. Public and secret-free by design: everything here lands in a
filesystem snapshot that's cached and reused for about a week, so nothing that touches
a credential belongs in this repository.

## Two-phase rule

| Phase                         | File                     | Runs                                              | Contains                                                                |
| ----------------------------- | ------------------------ | ------------------------------------------------- | ----------------------------------------------------------------------- |
| Setup (once, snapshotted)     | `bootstrap.sh`           | As root, before Claude Code launches              | Tools only — mise, tailscale, op CLI, toolchain warm-up. Never secrets. |
| Session start (every session) | `hooks/session-start.sh` | After Claude Code launches, on every start/resume | Secrets and per-session state — tailnet join, 1Password-backed config.  |

The split exists because the setup script's output is snapshotted for reuse; anything
written there would leak into every future session's filesystem. Secrets only ever flow
through `hooks/session-start.sh`, which runs fresh each time.

## Setup script

Every environment's web-UI "Setup script" field pastes the same three lines:

```bash
# claude-cloud-env v1 — bump this comment to force a cache rebuild
curl -fsSL https://raw.githubusercontent.com/LukeEvansTech/claude-cloud-env/main/bootstrap.sh -o /tmp/ccenv-bootstrap.sh
bash /tmp/ccenv-bootstrap.sh
```

`raw.githubusercontent.com` is on the default network allowlist, so this works even on
the most restricted network access level. Bumping the version comment forces a cache
rebuild the next time an environment starts.

## Git identity

The cloud harness commits as `Claude <noreply@anthropic.com>`, so every squash-merge
lands on GitHub with Claude as the author plus a `Co-authored-by: Claude` trailer.
`hooks/session-start.sh` sets `git config --global user.name` / `user.email` to the
account owner's GitHub noreply address instead, and reports whether the harness also
exports `GIT_AUTHOR_*` / `GIT_COMMITTER_*` — those env vars override Git config, so
when that warning appears the identity has to be cleared per command
(`env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL … git commit`).

## Environment catalog

The per-environment definitions (network access level, env vars, 1Password item
references) are documented in the local claudecode docs repository, not here — this
repository only holds the scripts they fetch.
