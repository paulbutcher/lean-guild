<!--
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-->

# Deploying a project

A project builds a kit executable from its configuration and text (`def main := Guild.Kit.main project text`), and keeps a settings file for each deployment. The kit's scripts take both from the environment: `KIT` is the executable and `KIT_ENV` the settings file. Each script runs `$KIT export` into `$STATE_DIR/config` first, so a configuration change reaches the deployment the next time any script runs.

## Settings

- Required: `FORGE_ORG`, `HUMAN_USER`, `HUMAN_EMAIL`, `FORGE_WEB_URL`; `FORGE_PORT` publishes Forgejo on localhost only.
- `COMPOSE_PROJECT_NAME` and `STATE_DIR` name the deployment and hold its secrets, control files and exported configuration, a relative `STATE_DIR` being relative to the settings file; `CI_IMAGE` and `TOOLCHAIN_VOLUME` name what CI jobs run in and the toolchains they share.
- `MIRRORS=off` makes a deployment that creates, changes and syncs no push mirror, whatever the configuration says; `MIRROR_BASE` replaces `https://github.com` as where mirrors go.
- Timings: `GATEKEEPER_SWEEP_SECONDS` (900) is how often the gatekeeper looks at every open pull request, in case it missed a webhook; the dispatcher's keep the reference's names and defaults (`DEBOUNCE_SECONDS`, `RECONCILE_SECONDS`, `IDLE_SECONDS` and the rest, listed in `compose.yaml`). `DISPATCHER_PORT` (3001) publishes its status JSON on localhost.
- Agents start only once `secrets/claude/oauth-token` holds a token from `claude setup-token`. One the kit has never started, having no workspace volume, starts stopped, for you to start in the web UI; `NEW_AGENTS=running` starts it at once.

## The web UI

- It is at `http://localhost:$UI_PORT/` (3002), published on localhost only, on no network an agent is on. Sign in with the key in `secrets/ui/key`, which `scripts/up.sh` makes.
- It shows the kit, agents, notices, activity and reviews, and pauses, drains and resumes the kit, stops and starts agents, stops runs and marks notices seen. Each page answers with its data as JSON when asked for `application/json`.
- Pause and resume cancel and remake scheduled merges in the human's name, with `secrets/human/token`, as the reference's scripts did.

## Backups

- `scripts/backup.sh` puts Forgejo's dump, the run ledger and the run archive in a folder of `backups/` named by the time, keeping the newest `BACKUP_KEEP` (7); `secrets/` and `control/` are not in it. `scripts/backup-install.sh` runs it daily at 03:30 on a Mac, and elsewhere prints a crontab line.
- `scripts/restore-test.sh [BACKUP]` restores the newest, or the one named, into a throwaway Forgejo that can reach nothing, on `RESTORE_TEST_PORT` (3003), and compares it with what the live one held.
- `scripts/restore.sh BACKUP` replaces Forgejo, the ledger and the archive with a backup, keeping a raw copy of the Forgejo it replaces, and starts the kit again. It needs the deployment's own `secrets/`.

## Your own commands

- `scripts/release.sh REPOSITORY` shows what a release would be; with a note and issues, it releases as you, at any level and while paused.
- `scripts/milestone.sh NAME` opens the milestone issue that wakes the milestone reviewers; `--diff` shows the API.lock changes it would carry.
- `scripts/new-library.sh REPOSITORY NAME` seeds a library the configuration already names, with a package that builds and passes CI.
- `scripts/open.sh AGENT` opens VS Code in an agent's container; `scripts/remote.sh` starts, attaches to or stops your Remote Control sessions with agents; `scripts/kit.sh` runs a tools command.

## The macOS runner

- A configuration with `layers.macos` has a `macos` CI job: the browser tests again, in Safari, WebKit and Chrome on the Mac's GPU. It is skipped unless `MACOS_RUNNER=on`, which needs a runner on the Mac that hosts the kit.
- On that Mac, install Tart (`brew install openai/tools/tart`), set `MACOS_RUNNER=on`, run `scripts/up.sh` and `scripts/bootstrap.sh`, then `scripts/macos-runner.sh image` once, naming the Lean toolchains to preinstall, and keep `scripts/macos-runner.sh run` going: each job gets a fresh VM, which is thrown away after it.
- At most two macOS VMs run at once on a Mac, and the job's VM comes out of what the kit has.

## Switching back to the reference

- Drain the guild, and while it is still up run `scripts/switch-back.sh`: it lists each open item the reference would find blocked on more than the guild does, since the reference reads every `Blocked-by:` line where the guild reads the newest comment's. Edit the lines it names out, run it again until it lists nothing, then stop the guild, run `scripts/switch-back.sh --hand-back` to give the ledger to the reference's dispatcher, which runs as uid 1000 whatever the host's is, and start the reference.

## Scripts

- `scripts/up.sh` builds the images up to the configuration's top layer (Lasm if it has it, else Lean) and the kit's own executables, and starts the kit; `scripts/down.sh` stops it.
- `scripts/bootstrap.sh` makes the human's account, then everything the configuration names: repositories, agents, teams, webhooks, labels and mirrors. It is idempotent; its last line is the number of changes made.
- `scripts/setup-repo.sh [REPOSITORY LEVEL]` applies an autonomy level, or each repository's starting level; run it after a repository's first push, since it protects `main`. It exits 3 when it has opened a pull request with files the level needs.
- `scripts/mirrors.sh [--rotate | --status]` converges push mirrors, rotates their token from `secrets/github/mirror-token`, or shows their last sync.
- `test/stages/stage3.sh` deploys the test projects in the dev container's engine and checks the networks, CI, permissions and mirrors; `test/stages/stage4.sh` runs the forge contract tests against a fresh deployment, as `lake test` runs them against the fake; `test/stages/stage5.sh` runs the gatekeeper through the reference's level 2 checks and a release; `test/stages/stage6.sh` runs the agents' tools in their own image against the forge; `test/stages/stage7.sh` runs the dispatcher, with its runners stood in for over HTTP; `test/stages/stage8.sh` runs the reference's stage 4 checks through the web UI; `test/stages/stage9.sh` runs the reference's stage 8 backup checks, a restore and the human's commands; `test/stages/stage12.sh` runs the browser tests in CI, and with `MACOS=1` waits for the macOS runner; `test/stages/runs.sh` runs the dispatcher with real Claude runs, given a token from `claude setup-token` in `./token`; `test/stages/switch.sh` replaces the reference kit with the guild and back.
