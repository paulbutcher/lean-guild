/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

public import Css

@[expose] public section

namespace Guild.Ui

open Css

/-- The theme's colours, set for light and for dark. -/
def fg : CustomProp Color := .named "fg"
def bg : CustomProp Color := .named "bg"
def muted : CustomProp Color := .named "muted"
def line : CustomProp Color := .named "line"
def accent : CustomProp Color := .named "accent"
def raised : CustomProp Color := .named "raised"

/-- A badge's tone: its background and its text. -/
structure ToneColors where
  name : String
  light : Color × Color
  dark : Color × Color

def tones : List ToneColors :=
  [{ name := "go", light := (.hex 0xdafbe1, .hex 0x116329), dark := (.hex 0x12351f, .hex 0x6fdd8b) },
   { name := "hold", light := (.hex 0xfff1c2, .hex 0x7a4d00), dark := (.hex 0x3b2e00, .hex 0xe3b341) },
   { name := "stop", light := (.hex 0xffe0e0, .hex 0xa40e26), dark := (.hex 0x4a1418, .hex 0xff9492) },
   { name := "quiet", light := (.hex 0xeaeef2, .hex 0x424a53), dark := (.hex 0x2d333b, .hex 0xadbac7) }]

def toneBg (t : ToneColors) : CustomProp Color := .named s!"{t.name}-bg"
def toneFg (t : ToneColors) : CustomProp Color := .named s!"{t.name}-fg"

def ident (s : String) : Value := [.ident s]

/-- Controls take the page's font rather than the browser's own. -/
def fontInherit : Declaration := { property := "font", value := ident "inherit" }

/-- A border in the theme's line colour. -/
def lined (p : Property Border) : Declaration :=
  { property := p.name, value := toValue (px 1) ++ ident "solid" ++ line.var }

def stylesheet : Stylesheet := [
  rule [tag "html"] ([declare "color-scheme" ([.ident "light", .ident "dark"] : Value),
    fg (.hex 0x1f2328), bg (.hex 0xffffff), muted (.hex 0x656d76), line (.hex 0xd8dee4),
    accent (.hex 0x0b5cad), raised (.hex 0xf6f8fa)] ++
    tones.flatMap fun t => [toneBg t t.light.1, toneFg t t.light.2]),
  media [.prefersColorScheme .dark] [
    rule [tag "html"] ([fg (.hex 0xe6edf3), bg (.hex 0x0d1117), muted (.hex 0x8d96a0),
      line (.hex 0x30363d), accent (.hex 0x4493f8), raised (.hex 0x161b22)] ++
      tones.flatMap fun t => [toneBg t t.dark.1, toneFg t t.dark.2])],
  rule [tag "body"] [margin 0, fontFamily ⟨.generic .systemUi, [.generic .sansSerif]⟩, lineHeight 1.45,
    color.var fg, backgroundColor.var bg],
  rule [tag "header"] [display .flex, flexWrap .wrap, justifyContent .spaceBetween, alignItems .center,
    gap (px 8), padding (.two (px 8) (px 24)), lined borderBottom],
  rule [descendant (tag "nav") (tag "a")] [marginRight (px 18), color.var accent, textDecoration .none],
  rule [descendant (tag "nav") (tag "a" ++ class_ "here")] [fontWeight 600, color.var fg],
  rule [tag "a"] [color.var accent],
  rule [tag "main"] [maxWidth (rem 72), padding (.three (px 8) (px 24) (px 40))],
  rule [tag "p", tag "li"] [maxWidth (ch 75)],
  rule [tag "p"] [margin (.two (px 6) 0)],
  rule [tag "h1"] [fontSize (px 26), margin (.three (px 16) 0 (px 12))],
  rule [tag "h2"] [fontSize (px 19), margin (.three (px 28) 0 (px 8))],
  rule [tag "h3"] [fontSize (px 15), margin (.three (px 18) 0 (px 6)), color.var muted],
  rule [tag "section"] [marginTop (px 36)],
  rule [tag "ul"] [paddingLeft (px 18), margin (.two (px 6) 0)],
  rule [tag "code"] [fontSize (px 13)],
  rule [tag "time"] [cursor .help],
  rule [tag "button"] [marginRight (px 8), padding (.two (px 5) (px 14)), cursor .pointer, fontInherit,
    color.var fg, backgroundColor.var raised, lined border, borderRadius (px 6)],
  rule [tag "input"] [padding (.two (px 5) (px 8)), fontInherit, color.var fg, backgroundColor.var bg,
    lined border, borderRadius (px 6), width (rem 24)],
  -- Tables scroll sideways in their own box rather than wrap their cells; prose cells wrap.
  rule [class_ "scroll"] [overflowX .auto, margin (.three (px 4) 0 (px 12))],
  rule [tag "table"] [declare "border-collapse" (ident "collapse"), minWidth (pct 100)],
  rule [tag "th", tag "td"] [padding (.two (px 6) (px 10)), textAlign .left, verticalAlign .top,
    whiteSpace .nowrap, lined borderBottom],
  rule [tag "th"] [fontSize (px 13), fontWeight 600, color.var muted],
  rule [tag "td" ++ class_ "wide"] [whiteSpace .normal, minWidth (rem 18)],
  rule [tag "td" ++ class_ "num"] [textAlign .right, declare "font-variant-numeric" (ident "tabular-nums")],
  rule [descendant (tag "tr" ++ class_ "unseen") (tag "td")] [fontWeight 600],
  rule [descendant (tag "td") (tag "p"), descendant (tag "td") (tag "button")] [margin 0],
  rule [class_ "badge"] [display .inlineBlock, padding (.two (px 1) (px 8)), borderRadius (px 999),
    fontSize (px 12.5), fontWeight 600, lineHeight 1.5, verticalAlign .middle]] ++
  tones.map (fun t => rule [class_ "badge" ++ class_ t.name] [backgroundColor.var (toneBg t), color.var (toneFg t)]) ++ [
  rule [class_ "secondary", tag "small"] [color.var muted, fontSize (px 12.5)],
  rule [class_ "brake", class_ "report"] [padding (.two (px 10) (px 16)), lined border, borderRadius (px 8),
    backgroundColor.var raised, margin (.three (px 8) 0 (px 16))],
  rule [descendant (class_ "brake") (tag "ul")] [margin 0],
  rule [class_ "summary"] [fontSize (px 17)],
  rule [class_ "error", class_ "failed"] [color.var (.named "stop-fg")]]

end Guild.Ui
