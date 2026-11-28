# Changelog

## v0.11.2

- The guild's dispatcher takes ownership of the ledger before it starts, so a switch from the reference works on a host whose uid isn't 1000.
- `scripts/switch-back.sh --hand-back` gives the ledger back to the reference's dispatcher once the guild is stopped.
- A unit's run budget counts no runs from before the guild first started on the ledger, so a switch from the reference raises no false alarms.

## v0.11.1

- A section at the end of a block leaves no blank line when it is off, so the Lasm tools list without the macOS runner is one list again.

## v0.11.0

- The Lasm layer's optional macOS runner: a `macos` CI job runs the browser tests in Safari, WebKit and Chrome on the Mac's GPU, in a Tart VM made for each job by `scripts/macos-runner.sh`, and is skipped unless the deployment's `MACOS_RUNNER` is on.
- With the macOS runner, the Lasm layer's instructions say how to launch Chromium so that it renders on the Mac's GPU.
- A CI job skipped by its condition counts as passed, where the dispatcher read it as still running.
- An agent named after one of the kit's own services is a configuration error.
- Stage 3's webhook check reads the dispatcher's own record of events again.

## v0.10.0

- The Lean layer's prior-art searches include awesome-lean-programming, beside Reservoir.
- An agent the kit has never started, having no workspace volume, comes up stopped for the human to start in the web UI; `NEW_AGENTS=running` turns this off.
- `scripts/switch-back.sh` lists each open item whose replaced `Blocked-by:` lines the reference would read again, for the human to edit out before switching back.
- PROTOCOL.md's differences from the reference list v0.9.0's changes to `Blocked-by:` lines and marker-only comments.
- REQUIREMENTS.md says the reference already took the newest `Waiting-on:` line, as v0.9.0 does for `Blocked-by:`.

## v0.9.0

- The randomised world test runs in `lake test`: Plausible worlds from the forge's data model, the real dispatcher and simulated agents, checking that the kit never goes quiet with unowed work, never wakes an agent for what it can't change, and never re-runs a head past the limit.
- A comment made only of `Blocked-by:`, `Waiting-on:` or `Released in` lines wakes no one by itself.
- Whether work is unreleased comes from the release, a tag at main's head included, rather than from the `ready-for-release` label, which the coordination repository ignores.
- An item's newest comment with `Blocked-by:` lines replaces earlier comments' lines, and `Blocked-by: none` clears them, so no fix needs a comment edited.
- A loop's wake names each item and links each line, and a blocker that is released but open is named with what to do.
- The re-run refusal and the CI failing wake say when the head was re-run and what failed again.
- A run's re-runs and releases count as forge changes in the ledger.
- An outsider's pull request can be moved on by its owner's reply.

## v0.8.0

- Backups and restores: `scripts/backup.sh`, `restore.sh`, `restore-test.sh`, which checks a backup in a throwaway Forgejo, and `backup-install.sh` for a daily job.
- The human's own commands: `scripts/release.sh`, `milestone.sh`, `new-library.sh`, `open.sh` and `remote.sh`.
- The Lean layer has a library template, filled from the configuration, that `new-library.sh` seeds a library from.
- A script that runs another no longer gives compose the agents' services twice.

## v0.7.0

- The human's web UI, `guild-ui`, in its own container on no network an agent is on: the kit, agents, notices, activity and reviews, each also as JSON.
- Its actions pause, drain and resume the kit, stop and start agents, stop runs and mark notices seen, and pause and resume cancel and remake scheduled merges in the human's name.
- `changes_guarded` proves that no route that could change anything is reached without the anti-forgery token, nor, but for signing in, without a signed-in session.
- `Forge` gains `mergers`, which narrows or restores who may merge into a protected `main`.
- The dispatcher serves `/reviews` and marks notices seen, which restarts a unit's run budget, and the runner stops a run when `control/stop-run-<id>` appears.

## v0.6.0

- The dispatcher is in Lean, `guild-dispatcher`, with the reference's ledger, so a project can switch between the reference's kit and the guild and back.
- Obligations wake with the patience fix and the run budget, and CI that fails again with its re-runs spent notifies the human.
- An agent stops taking work while `control/stopped-<agent>` exists.
- The kit generates each agent's service from the configuration, and `scripts/up.sh` starts the agents once they have a Claude token.
- The export adds `config.json`, rewrites only the files that changed so running containers keep them, and `Config` has JSON codecs.
- `Forge.Pull` gains `createdAt` and `mergedAt`, and the Forgejo adapter reads an empty repository's pull requests as none.
- Agents run as the host user, so they can write their workspaces.

## v0.5.0

- The agents' tools are in Lean: `guild-hook` guards the human's sessions and brakes runs while paused, `forge` does what `tea` can't, and `guild-runner` runs and reports each run.
- `forge ci --rerun` refuses past the configured re-run limit, counted from the forge, and `forge ci` says how many times the head was re-run.
- The guard treats a newline as a command separator, as bash does, which the reference did not.
- The kit's export adds the agents' git rules (`gitconfig`) and the settings `forge` and the runner read.

## v0.4.0

- The gatekeeper approves pull requests on CI at levels 2 and 3 and releases at level 3, in Lean, reading the pause from `control/`.
- Webhooks are parsed and their signatures checked by the forge adapter, and `createRelease` returns the release's web address.
- `GATEKEEPER_SWEEP_SECONDS` sets how often the gatekeeper looks at every open pull request.

## v0.3.0

- Everything the kit does through a forge goes through a `Guild.Forge.Forge` per account, with a Forgejo adapter, and CI re-runs of a commit are counted from the forge.
- Contract tests hold a fake forge to what a real Forgejo does: paging, dropped labels, `updated_at`, requested reviewers, scheduled merges and re-runs.

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
