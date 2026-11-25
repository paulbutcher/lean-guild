<!--
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-->

# Deploying a project

A project builds a kit executable from its configuration and text (`def main := Guild.Kit.main project text`), and keeps a settings file for each deployment. The kit's scripts take both from the environment: `KIT` is the executable and `KIT_ENV` the settings file. Each script runs `$KIT export` into `$STATE_DIR/config` first, so a configuration change reaches the deployment the next time any script runs.

## Settings

- Required: `FORGE_ORG`, `HUMAN_USER`, `HUMAN_EMAIL`, `FORGE_WEB_URL`; `FORGE_PORT` publishes Forgejo on localhost only.
- `COMPOSE_PROJECT_NAME` and `STATE_DIR` name the deployment and hold its secrets, control files and exported configuration; a relative `STATE_DIR` is relative to the settings file.
- `CI_IMAGE` and `TOOLCHAIN_VOLUME` name what CI jobs run in and the toolchains they share.
- `MIRRORS=off` makes a deployment that creates, changes and syncs no push mirror, whatever the configuration says; `MIRROR_BASE` replaces `https://github.com` as where mirrors go.

## Scripts

- `scripts/up.sh` builds the images up to the configuration's top layer (Lasm if it has it, else Lean) and starts the kit; `scripts/down.sh` stops it.
- `scripts/bootstrap.sh` makes the human's account, then everything the configuration names: repositories, agents, teams, webhooks, labels and mirrors. It is idempotent; its last line is the number of changes made.
- `scripts/setup-repo.sh [REPOSITORY LEVEL]` applies an autonomy level, or each repository's starting level; run it after a repository's first push, since it protects `main`. It exits 3 when it has opened a pull request with files the level needs.
- `scripts/mirrors.sh [--rotate | --status]` converges push mirrors, rotates their token from `secrets/github/mirror-token`, or shows their last sync.
- `test/stages/stage3.sh` deploys the test projects in the dev container's engine and checks the networks, CI, permissions and mirrors; `test/stages/stage4.sh` runs the forge contract tests against a fresh deployment, as `lake test` runs them against the fake.
