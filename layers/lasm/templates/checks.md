@@ install

      # Lasm and browser tests run where an npm project pins them: the test
      # subproject (test/package-lock.json) or an application's app/
      # (app/package-lock.json). Its packages may come from Lake's (file:
      # paths into .lake/packages), so this runs after the build.
      - name: Install Lasm
        run: |
          found=
          for d in test app; do
            if [ -f "$d/package-lock.json" ]; then
              (cd "$d" && npm ci --no-fund --no-audit)
              found=1
            fi
          done
          [ -n "$found" ] || echo "No test/ or app/ package-lock.json; Lasm tests are skipped."

@@ require
          # Fail, rather than skip with a warning, if Lasm is pinned but missing.
          if [ -f test/package-lock.json ] || [ -f app/package-lock.json ]; then export {{REQUIRE_LASM}}=1; fi

@@ site

      # A site's release tags are deployed to GitHub Pages by
      # .github/workflows/pages.yml, which runs scripts/build-site.sh: build
      # it here first, so a broken site never reaches a tag.
      - name: Site builds
        run: |
          if [ -f scripts/build-site.sh ]; then
            bash scripts/build-site.sh
            if [ ! -f _site/index.html ]; then
              echo "::error::scripts/build-site.sh left no _site/index.html"
              exit 1
            fi
          else
            echo "No scripts/build-site.sh; not a site."
          fi

@@ macos

  # The browser tests again, in Safari, WebKit and Chrome on the GPU, on a macOS runner: a Tart VM
  # on the host, made for one job and then thrown away. Skipped where no runner serves the
  # deployment (its MACOS_RUNNER setting).
  macos:
    if: vars.MACOS_RUNNER == 'on'
    runs-on: macos
    env:
      TOKEN: ${{ secrets.DEPS_READ_TOKEN }}
      GH_OWNERS: ${{ vars.DEPS_GITHUB_OWNERS }}
      DEPS_REPOSITORIES: ${{ vars.DEPS_REPOSITORIES }}
      GUILD_BROWSERS: safari webkit chromium
    steps:
      - name: Check out
        run: |
          echo "$HOME/.elan/bin" >> "$GITHUB_PATH"
{{>checkout}}

      - name: Build
        run: lake build
{{>lasm:install}}

      - name: Browser tests
        run: |
          export {{REQUIRE_LASM}}=1
          lake test
