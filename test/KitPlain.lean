/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import GuildTests.Projects

def main (args : List String) : IO UInt32 :=
  Guild.Kit.main GuildTests.Projects.plain GuildTests.Projects.plainText args
