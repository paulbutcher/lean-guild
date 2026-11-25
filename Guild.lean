/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Guild.Core.Issue
import Guild.Core.Pull
import Guild.Core.Release
import Guild.Core.Milestone
import Guild.Core.Kit
import Guild.Core.Obligation
import Guild.Core.Holder
import Guild.Core.Deadline
import Guild.Core.Waits
import Guild.Core.Rerun
import Guild.Core.Budget
import Guild.Core.Version
import Guild.Config
import Guild.Settings
import Guild.Template
import Guild.Protocol
import Guild.Kit
-- Dependencies the kit will use, so that `lake build` proves each builds on this toolchain.
import Leancurl
import SQLite
import Json
import Html
import Htmx
import Css
import Routing
import RoutingStd
import Middleware
import MiddlewareCookieStore
