# Agents' instructions

Each agent's instructions are its role, through its kind's template, then the protocol. The kit writes the protocol and every kind's template, the Lean and Lasm layers add their blocks, and the project writes a role for each agent and blocks of its own. `Guild.Protocol.assemble` renders them; `Guild.Protocol.check` reports a role missing, a role for no agent, text that doesn't render, and a block nothing uses.

## What a project writes

- **A role for each agent:** its text, which its kind's template places first, then any blocks the template has room for, each starting with a line `@@ <name>`.
- **Project blocks** for the protocol, in one file of `@@ <name>` blocks. Each goes where the protocol leaves room for it, and a block may sit mid-sentence, so it loses its trailing newlines.
- Text may use the values and flags below, as `{{NAME}}` and `{{#flag}}…{{/flag}}` (or `{{^flag}}` for off), and render other blocks with `{{>name}}`.

| Where | Blocks it has room for |
|---|---|
| Coordinator's template | `duties`, after the kit's list of duties |
| Milestone reviewer's | `review`: what to gather and ask, before the kit's reporting rules |
| Site's (Lasm) | `after-deployment`, after the kit's deployment rules |
| The protocol | `trust`, `tools`, `working-in-your-repository`, `comments`, `conventions` at the end of those sections; `reuse-reasons`, why upstream code may not do; `cross-cutting`, mid-sentence after "cross-cutting sections"; `definition-of-done`, mid-sentence after "against your repository's `CLAUDE.md`"; `conformance`, among the reviewer's checks |

## Values and flags

| Value | What it is |
|---|---|
| `AGENT`, `REPO` | The agent, and the repository it owns, if it owns one |
| `ORG`, `HUMAN`, `FORGE_WEB_URL` | Settings: the forge organisation, the human's account, the forge as their browser reaches it |
| `PROJECT`, `COORDINATION`, `REPOS`, `LIBRARIES` | The project's name, its coordination repository, all its repositories as a list, and all but the coordination repository |
| `COORDINATOR`, `REVIEWER`, `SUPERVISOR` | The agents of those kinds, where the project has one |
| `GH_OWNER` | The GitHub owner, where the project mirrors to GitHub |
| `UPSTREAM` | The upstream project the agent tracks, if any |
| `HUMAN_ONLY`, `HUMAN_ONLY_OR`, `FORGE_DIR`, `WORKSPACE_STATE` | The files only the human changes, as a list joined with "and" or with "or"; `.forgejo/`; the workspaces' state directory |
| `WAKES`, `WAKES_AFTER_RUN`, `TRIES`, `ROUNDS`, `RERUNS`, `NUDGES` | The bounds in words; `WAKES_AFTER_RUN` says the first wake comes when the run ends |

Flags: `lasm`, `macos`, `mirrored`, `imported` (history imported into Forgejo), `reviewer`, `supervisor` and `milestoneReviews` (the project has such agents), `tracks` and `owns` (this agent tracks an upstream project, owns a repository).

## Differences from the reference

What a project's assembled instructions say differently from the reference's rendered ones, inkproof-forge at the commit [PLAN.md](PLAN.md#the-reference) names.

- **Project text moves.** A coordinator's own duties come after the kit's list rather than among it, and a milestone reviewer's questions sit between the kit's opening and its reporting rules.
- **Requirement IDs and examples are gone.** The kit's text names no project's requirements (ARCH-1, PLAT-3, FP-3) or issues (`inkproof-demo#35`, `inkproof-coordination#235`); "every `inkproof-` repository" becomes "every repository of the project" or the list of repositories, and the reuse order's first step lists them.
- **Kit names.** `/usr/local/share/guild/` and `/var/lib/guild/` replace the reference's `inkproof` paths, and the workspaces' state directory is a setting.
- **Bounds in words.** Wake counts, review rounds and the supervisor's nudges come from configuration. "A few rounds" becomes the rounds limit, and the Comments section's "followed by another at once, then two more 15 minutes apart" reads "followed by another at once, then twice more 15 minutes apart".
- **New behaviour.** A CI re-run is refused past the limit (property 8), and the coordinator takes `ready-for-release` off an upstream issue closed before its release rather than reopening it.
- **"Repository" for "library or site".** Where the reference names an agent's "library or site", the kit's text says "repository": filing an issue on your own repository, owning no repository, and your repository's requirements.
- **Smaller wording.** The milestone reviewers' report wording is shared, so the Lasm reviewer's "finding" reads "recommendation"; the site's deployment names `{{GH_OWNER}}` and its repository, and drops Node's version and Vite; and the conformance reviewer's reuse check drops its examples.
