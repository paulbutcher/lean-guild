/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Kit

/-! The guild's own test projects: a plain Lean one, and a small one that targets the browser. -/

namespace GuildTests.Projects

open Guild

def settings : Settings :=
  { forgeOrg := "testorg", human := "tester", forgeWebUrl := "http://localhost:3300" }

/-- A plain Lean project, with every kind of agent but a site. -/
def plain : Project where
  config :=
    { name := "the Testbed libraries"
      coordination := "testbed-coordination"
      repositories :=
        [{ name := "testbed-coordination" },
         { name := "testbed-base", level := 2 },
         { name := "testbed-app", dependsOn := ["testbed-base"], level := 3 }]
      agents :=
        [{ name := "coordinator", kind := .coordinator, owns := some "testbed-coordination",
           filesOn := .all },
         { name := "base", kind := .library, owns := some "testbed-base",
           filesOn := .only ["testbed-coordination"] },
         { name := "app", kind := .library, owns := some "testbed-app",
           filesOn := .only ["testbed-coordination", "testbed-base"] },
         { name := "conformance", kind := .prReviewer, filesOn := .all },
         { name := "architecture", kind := .milestoneReviewer, filesOn := .all },
         { name := "process", kind := .supervisor, filesOn := .all, humanDecides := true }]
      bounds := { patience := 3, runBudget := 40 }
      forge := .forgejo (some { owner := "testbed", formerOwners := ["testbed-old"] }) false
      template := { namespaceRoot := "Testbed", readmeLine := "Part of the Testbed libraries." } }

def plainText : Protocol.Text where
  roles :=
    [("coordinator", "# Role: coordinator\n\nYou own `testbed-coordination`: `REQUIREMENTS.md` and `ROADMAP.md`.\n"),
     ("base", "# Role: owner of Testbed.Base\n\nYou own `testbed-base`.\n"),
     ("app", "# Role: owner of Testbed.App\n\nYou own `testbed-app`.\n\n- Dependencies: `testbed-base`.\n"),
     ("conformance", "# Role: conformance reviewer\n"),
     ("architecture", "# Role: architecture reviewer\n\n@@ review\nAsk whether the boundaries between libraries are in the right place.\n"),
     ("process", "# Role: process reviewer and supervisor\n")]
  sections := "@@ cross-cutting\n (correctness and performance)\n"

/-- A project that targets the browser: a library, a site, an upstream project its milestone
reviewer tracks, and push mirrors. -/
def browser : Project where
  config :=
    { name := "the Webbed libraries"
      coordination := "webbed-coordination"
      repositories :=
        [{ name := "webbed-coordination" },
         { name := "webbed-ui" },
         { name := "webbed-site", dependsOn := ["webbed-ui"] }]
      agents :=
        [{ name := "coordinator", kind := .coordinator, owns := some "webbed-coordination",
           filesOn := .all },
         { name := "widgets", kind := .library, owns := some "webbed-ui",
           filesOn := .only ["webbed-coordination"] },
         { name := "site", kind := .site, owns := some "webbed-site",
           filesOn := .only ["webbed-coordination", "webbed-ui"] },
         { name := "lasm", kind := .milestoneReviewer, filesOn := .all, humanDecides := true }]
      upstreams := [{ name := "lasm", title := "Lasm", tracker := some "lasm" }]
      bounds := { patience := 2, runBudget := 30 }
      layers := { lasm := true, macos := true }
      forge := .forgejo (some { owner := "webbed", formerOwners := ["oldowner"] }) true
      template := { namespaceRoot := "Webbed", readmeLine := "Part of the Webbed libraries.",
                    seedFrom := some "webbed-ui" } }

def browserText : Protocol.Text where
  roles :=
    [("coordinator", "# Role: coordinator\n\nYou own `webbed-coordination`.\n"),
     ("widgets", "# Role: owner of Webbed.Ui\n\nYou own `webbed-ui`.\n"),
     ("site", "# Role: owner of the site\n\nYou own `webbed-site`, a public site.\n\n- Dependencies: `webbed-ui`.\n@@ after-deployment\n- Keep each page's source short.\n"),
     ("lasm", "# Role: Lasm reviewer\n\n@@ review\nGather what the libraries had to do to work with Lasm.\n")]

end GuildTests.Projects
