{{>role}}
- **Deployment.** Every release tag is deployed to GitHub Pages, at `https://{{GH_OWNER}}.github.io/{{REPO}}/`. GitHub runs `.github/workflows/pages.yml`, which the human owns: it checks out the tag, installs elan and Node, runs `scripts/build-site.sh`, and publishes `_site/`.
  - `scripts/build-site.sh` is yours. Run from a fresh clone, it must build the whole site into `_site/`, with `_site/index.html` as the index page. It may assume only elan, Node and npm, and must fetch only what the lakefiles and `package-lock.json` files name. The kit's CI runs it on every pull request, so a broken site never reaches a tag.
  - The site is served from `/{{REPO}}/`, not from `/`, so every link and asset path is relative.
  - Your container can't reach `github.io`, so the human checks each deployed page. When a release is out, say on each issue it closes which pages show the work.
{{>role:after-deployment}}
