# Plan

The order of work for the guild, from an empty repository to a kit a project can switch to. [REQUIREMENTS.md](REQUIREMENTS.md) says what each stage builds; this file says in what order, how each is accepted, and where it waits on [inkproof-guild](https://github.com/paulbutcher/inkproof-guild), the first consuming project. That repository's `docs/COORDINATION.md` holds the order of both repositories together.

## The reference

- [inkproof-forge](https://github.com/paulbutcher/inkproof-forge) at commit `c82e23a54bc2854f18130d88a519d9e63766836d`.
- Clone it with `git clone https://github.com/paulbutcher/inkproof-forge ../inkproof-forge && git -C ../inkproof-forge checkout c82e23a54bc2854f18130d88a519d9e63766836d`. Read it; never change it.

## How to work

- One session per stage. Start by reading REQUIREMENTS.md, this file and the stage's sources in the reference; work only on the first stage not marked done.
- A stage is done when its acceptance passes in the dev container. Then mark it done here, with the date, and propose a `CHANGELOG.md` entry; the human commits and tags.
- If a stage needs something from the consuming project, or reveals that the project interface must change, stop and draft an issue for the other repository as raw markdown; the human files it.
- Record a decision that settles something REQUIREMENTS.md left open in REQUIREMENTS.md itself, in the same change.
- Never run anything against a real project's forge, and never run stage tests on the host's own Docker engine: the host runs a production kit.

## Stages

| # | Stage | Builds | Acceptance | Waits on |
|---|---|---|---|---|
| 0 | Foundations | Layout (`Guild/`, `layers/lean/`, `layers/lasm/`, a `test` subproject), dependencies pinned and building on this toolchain (leancurl, leansqlite, lean-json, the web stack, Plausible), a dev container with its own Docker engine (the reference's `.devcontainer` shows how), CI, an empty `CHANGELOG.md` | `lake build` and `lake test` in CI; `docker run hello-world` in the dev container | |
| 1 | The pure core | Facts and states for every unit, obligations and the scheduler, with the patience fix, property 8's attempt counts and the run budget; the theorems in REQUIREMENTS.md, "States and the scheduler" | theorems compile, with standard axioms only; every deliberate difference from `states.py` listed in CHANGELOG | |
| 2 | The project interface | Configuration types, layer selection, the repository contract, rules that named agents made configuration, protocol assembly (kit, kind, layer and project sections, with placeholders) | the guild's test projects and inkproof-guild's inventory are expressible; human tags `v0.1.0` | inkproof-guild stage 1 (the inventory) |
| 3 | The kit's infrastructure | Compose files, Forgejo, proxies and joined allowlists, CI with its own engine, staged images (base, Lean, Lasm with WebKit), bootstrap and repository setup in shell with push mirrors, the rules resolving GitHub URLs to Forgejo, the two test projects | ported stage 1; mirrors push to a second repository in the test Forgejo, never to GitHub; a test project that mirrors, deployed with mirrors off, bootstraps with no mirror and nothing leaving the test Forgejo; CI fetches a dependency named by GitHub URL from Forgejo | |
| 4 | The forge adapter | The adapter interface, the Forgejo adapter, a fake forge for unit tests, contract tests against the real Forgejo | contract tests pass against Forgejo and the fake alike | |
| 5 | The gatekeeper | Webhooks, CI checks, approvals and releases, as the first whole service; the control state it reads | the reference's gatekeeper tests (`test_gatekeeper.py`) ported; ported stage 6, pausing through the control state | |
| 6 | The agents' tools | The tool-call hook, `forge` (with the re-run limit), the agent runner | ported `test-hook.sh`; `forge ci --rerun` refuses past the limit, counted from the forge | |
| 7 | The dispatcher | The reference's dispatcher tests ported first, then fact reading, the item cache, CI flags, webhooks and the sweep, the ledger, notices, obligations and the run budget; the JSON the UI's pages will serve | ported stages 3, 4, 5, 7 and 9, reading that JSON where they read `status.sh` and setting the control state where they ran `pause.sh`, `resume.sh` or `drain.sh`; a CI that always fails the same way meets the re-run limit and notifies the human; a switch round trip: the reference's kit drained, stopped and replaced by the guild under the same compose project name and `STATE_DIR`, then the reverse, each finding the other's ledger, volumes, secrets and `control/` files | |
| 8 | The web UI | Read-only pages over stage 7's JSON, then actions, then activity and reviews; the session and anti-forgery proof | `lake test` over the views; stage 4's checks through the UI's JSON and actions | |
| 9 | Backups and the rest of the command line | Backups and restore, and every script REQUIREMENTS.md keeps on the command line, with mirror status and token rotation | ported stage 8 | |
| 10 | The randomised world test | Plausible worlds from the forge's data model, simulated agents, the "never quiet with unowed work" check | runs in `lake test`; any state it finds is added to stage 1's core | |

After stage 10 the human tags a release that inkproof-guild can switch to. The stages below come after that switch, and can be taken in either order.

| # | Stage | Builds | Acceptance |
|---|---|---|---|
| 11 | GitHub | The GitHub adapter, GitHub mode, import into Forgejo, adoption with onboarding pull requests, issues-only outside contributions | the ported stages against the fake forge in GitHub mode; then, sparingly, against real GitHub through a GitHub App on a test account the human provides, never a machine user, inside the limits in `github-forge-research.md` |
| 12 | The macOS runner | The Tart VM image, its runner, the optional `macos` job | the Lasm test project's browser tests run in Safari and WebKit on Metal |

## Status

| # | Done |
|---|---|
| 0 | 2026-11-25 |
| 1 | 2026-11-25 |
| 2 | 2026-11-25 |
| 3 | |
| 4 | |
| 5 | |
| 6 | |
| 7 | |
| 8 | |
| 9 | |
| 10 | |
| 11 | |
| 12 | |
