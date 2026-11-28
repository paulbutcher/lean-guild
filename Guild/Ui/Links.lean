/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Routing.RouteTable

@[expose] public section

namespace Guild.Ui

route_table Routes
  [ kit := "/",
    agents := "/agents",
    notices := "/notices",
    activity := "/activity",
    reviews := "/reviews",
    style := "/style.css",
    signIn := "/sign-in",
    signOut := "/sign-out",
    pause := "/kit/pause",
    drain := "/kit/drain",
    resume := "/kit/resume",
    stopRun := "/runs/:id:Nat/stop",
    stopAgent := "/agents/:name:String/stop",
    startAgent := "/agents/:name:String/start",
    seen := "/notices/:id:Nat/seen" ]

end Guild.Ui
