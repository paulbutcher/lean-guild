# Changelog

## v0.2.0

- The kit deploys a project: staged images, Forgejo, proxies with joined allowlists, CI in its own engine, bootstrap and repository setup, and push mirrors that a deployment can turn off with `MIRRORS=off`.
- CI fetches a dependency named by its GitHub URL from Forgejo.
- A project builds a kit executable with `Guild.Kit.main`, whose `export` command writes what the scripts read; `Config` gains `allowAgents` and `allowCi`, and `Settings` gains `MIRRORS` and `MIRROR_BASE`.
- `Bounds.patience` counts the runs of a busy agent that a quiet obligation lets go ahead of it.

## v0.1.1

- The protocol joins its lists of files and upstream projects with "or" where the sentence needs it, says the first wake again comes when a run ends, and points the reuse search at the libraries alone.

## v0.1.0

- A pull request whose mergeability the forge hasn't worked out by its deadline is `check stuck`, held by its author, where the reference waited on the forge indefinitely.
- A `Blocked-by:` line is invalid when it closes a loop through any waits between units, such as an issue waiting on a pull request that is blocked by the issue, not only a loop of `Blocked-by:` lines.
- A quiet obligation waits for its busy agent at most `patience` times, so an agent kept busy can no longer starve it unnoticed.
- CI re-runs are limited per head commit, counted from the forge, and spending the limit tells the human.
- Each unit has a budget of agent runs, past which the human gets one notice until they mark it seen.
- An upstream issue closed while ready for release is no longer reopened, which handed it back to the world to close again: the coordinator takes the label off instead.
- States' steps no longer name the reference's scripts, forge paths or fixed timings.
- A project's configuration is Lean values of the guild's types, checked when it compiles, with the rules that named agents derived from their kinds.
- Deployment settings are read from the environment, and a missing one is an error rather than a default.
- Each agent's instructions are assembled from the kit's protocol and kinds, the layers' blocks and the project's roles and blocks; [docs/PROTOCOL.md](docs/PROTOCOL.md) lists where they differ from the reference's.
