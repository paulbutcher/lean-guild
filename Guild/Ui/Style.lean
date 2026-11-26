/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Css

@[expose] public section

namespace Guild.Ui

open Css

def ink : Color := .hex 0x222222
def faint : Color := .hex 0x777777
def hairline : Color := .hex 0xdddddd
def accent : Color := .hex 0x2f5d8a

def stylesheet : Stylesheet := [
  rule [tag "body"] [margin 0, fontFamily ⟨"system-ui", [.sansSerif]⟩, lineHeight 1.45, color ink],
  rule [tag "header"] [padding (.two (px 10) (px 24)), borderBottom { width := px 1, style := .solid, color := hairline }],
  rule [descendant (tag "nav") (tag "a")] [marginRight (px 18), color accent, textDecoration .none],
  rule [descendant (tag "nav") (tag "a" ++ class_ "here")] [fontWeight 600, color ink],
  rule [tag "main"] [maxWidth (px 960), padding (.two (px 8) (px 24))],
  rule [tag "h2"] [marginTop (px 28), fontSize (px 20)],
  rule [tag "h3"] [marginBottom (px 4), fontSize (px 15), color faint],
  rule [tag "ul"] [paddingLeft (px 18)],
  rule [descendant (tag "li") (tag "p")] [margin (.two (px 2) 0)],
  rule [tag "button"] [marginRight (px 10), padding (.two (px 6) (px 14)), cursor .pointer],
  rule [class_ "summary"] [fontSize (px 18)],
  rule [class_ "unseen"] [fontWeight 600],
  rule [class_ "error"] [color (.hex 0xa33a3a)],
  rule [class_ "state"] [fontSize (px 14), fontWeight 400, color faint]]

end Guild.Ui
