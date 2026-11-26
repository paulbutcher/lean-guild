@@ tools
- Headless Chromium, for browser tests through Playwright (`PLAYWRIGHT_BROWSERS_PATH` is set). Pin `playwright` in `test/package.json` at exactly {{PLAYWRIGHT}}, the version installed here and in CI, and never run `playwright install`: browsers can't be downloaded.
{{#macos}}
- CI's `macos` job runs your browser tests on a Mac's GPU, in the browsers its `GUILD_BROWSERS` names: `safari` through `safaridriver`, and `webkit` and `chromium` through Playwright. There, launch Chromium with `channel: 'chromium'` and the arguments `--use-angle=metal` and `--ignore-gpu-blocklist`, or it renders in software.
{{/macos}}

@@ toolchain
, and Lasm's, which `npx lasm` manages

@@ toolchain-cache
 or Lasm's cache (`~/.cache/lasm`)

@@ new-dependency
, whether it works under Lasm

@@ bindings
 A browser API Lasm has no typed binding for doesn't stop you: write the binding in Lean in your own library, with Lasm.JS (`@[js "globalThis" "…"]`, or `Value.get` and `callMethod`), record it on the upstream issue, and carry on. Lean can't do everything JavaScript can, such as defining a class: only then does a shim, under your library's own rules for them, take the binding's place.

@@ site-released
, and for a site nothing is deployed until it is

@@ tested
 and, for code that runs in the browser, under Lasm

@@ site-versions
 So a site, whose `API.lock` rarely changes, mostly has patch releases.
