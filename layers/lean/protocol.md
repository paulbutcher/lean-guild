@@ toolchains
- Your toolchains are the ones CI uses: Lean's, installed by elan from `lean-toolchain` (with its own `clang`, which Lake uses){{>lasm:toolchain}}. Never modify, replace or wrap anything under `~/.elan`{{>lasm:toolchain-cache}}, never point one toolchain at another's files, and never install or improvise a compiler or other tool, not even in `/tmp` for one command. A build that works only because of such a change isn't one CI or anyone else can repeat. If a build needs a tool you don't have, stop and say so on the issue: the build is set up wrongly, or the gap is the human's to decide (Decisions for the human) or an upstream issue.

@@ api-lock
- Changes to `API.lock` (public declarations and theorem statements) need review: the human's at autonomy levels 1 and 2, the coordinator's at level 3. Say clearly in the pull request why the API must change, and which requirement each new or changed theorem statement meets.

@@ dependencies
## Dependencies

- Depend on other libraries only at release tags (`vX.Y.Z`), through their public API. Never depend on a branch or commit, and never import modules named `Internal`. CI enforces the pinning.
{{#mirrored}}
- Keep their GitHub URLs in `lakefile` and `lake-manifest.json`. Git fetches this project's repositories from Forgejo for you.
{{/mirrored}}

@@ reuse
Before designing anything new (a type, an algorithm, a group of lemmas), find out whether it already exists, in this order:

1. this project's other libraries, at `/workspace/<repo>`: the `README.md` of each of {{LIBRARIES}}, which lists what the library does by job, then its `API.lock`, and its source for private declarations. Search for the job, not a name: the same job under another name is still a repeat;
2. the catalogue of known libraries, `PRIOR-ART.md` in `{{COORDINATION}}`, which includes the human's own Lean libraries;
3. Lean core, Std, Batteries and Mathlib: search them with Loogle (`https://loogle.lean-lang.org/json?q=<query>`) or by reading their source;
4. other Lean packages, on Reservoir (`https://reservoir.lean-lang.org`).

Say in the pull request, in a `Prior art:` line, what you looked for, where, and what you found: the job in a few words, and the libraries and modules you checked for it, outside this project (Lean core, Std, Batteries, Mathlib, Reservoir) as well as in it. "None found" is a fine conclusion, but not a whole line, and code with no knowledge of your domain needs the search outside this project most: Lean core and Std hold far more than their names suggest (dates and time zones, parsing, formatting, arithmetic on `Nat`, `Int` and `Rat`). A request asking where something should live, or proposing a new library, carries the same line: a new library proposed without searching outside this project wastes the human's decision.

@@ definition-of-done
A pull request is ready only when the build passes without warnings, all tests pass natively{{>lasm:tested}}, and `API.lock` is up to date. Before opening one, read your own diff as {{#reviewer}}{{REVIEWER}}{{/reviewer}}{{^reviewer}}a reviewer{{/reviewer}} will, against your repository's `CLAUDE.md`{{>project:definition-of-done}}. A pull request that fixes a fault adds a test that fails on `main` before it and passes after: run it both ways, and say in the description that you did. If you can't make one fail, because only a device you don't have shows the fault or you couldn't reproduce it, say so plainly there and on the request, and call the fix unconfirmed: a test that passes either way guards against a regression but is no evidence of a fix. Update `CHANGELOG.md` only when preparing a release: a heading for the next version, in the form the file already uses (`## [X.Y.Z]`, or `## vX.Y.Z` in a new file), then one short sentence. A release is refused unless that heading names the version computed from `API.lock`, as follows. The version follows from `git diff <last release tag> -- API.lock`: before 1.0, minor if `API.lock` changed and patch otherwise; from 1.0, major if a line was removed or changed, minor if lines were only added, and patch otherwise.{{>lasm:site-versions}} Don't work it out: run `forge version` in your checkout, with `API.lock` up to date, and use the version it prints. If more work merges before the release, update the same entry, including its version, by running `forge version` again.
