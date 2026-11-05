class_name UiTokens
## The design tokens: every chrome colour, type size and spacing step.
##
## Values are the ones the app already renders with — seeded from the old
## `palette.gd` and the `SettingsManager` defaults — with TEXT_MUTED and DANGER
## raised until they clear 4.5:1. The status bar's right-hand text measured
## 4.15:1 and Close All 3.49:1 on the 0.7.2 build; both now pass.
##
## `CONTRAST_PAIRS` is the enforced table: a colour used as text on a surface
## belongs in it, and `godot/tests/unit/test_ui_tokens.gd` fails the build when
## a pair drops under 4.5:1. Pure constants and pure functions — no scene tree,
## no autoload — so a canvas or a unit test can use them directly.

# --- Surfaces -----------------------------------------------------------------
## The content area and the window's clear colour.
const BG := Color("1a1a1a")
## Panels, cards, popups and dialog bodies.
const SURFACE := Color("202128")
## Raised chrome: title bars, buttons, the status bar.
const SURFACE_RAISED := Color("2e2e33")
## The sidebar's own background.
const SIDEBAR := Color("1f1f26")
## The 1 px line on a panel edge or a separator.
const BORDER := Color("3a3d46")
## Text selection across every text surface.
const SELECTION := Color(0.3, 0.5, 1.0, 0.4)

# --- Text ---------------------------------------------------------------------
const TEXT := Color("e6e8ec")
## Secondary text: hints, the status bar's right-hand readout. 5.13:1 on SURFACE_RAISED.
const TEXT_MUTED := Color("9aa0aa")
## Disabled controls. Exempt from WCAG's text contrast minimum.
const TEXT_DISABLED := Color("767b85")

# --- Accents ------------------------------------------------------------------
## Focus, selection, the active row, a highlighted edge.
const ACCENT := Color("7fb4ff")
## The accent under the pointer.
const ACCENT_HOVER := Color("a6c9ff")
## A destructive action or verb. 5.56:1 on SURFACE_RAISED — a pure red cannot
## reach 4.5:1 on these backgrounds, so the G and B channels carry some weight.
const DANGER := Color("ff8080")
const WARNING := Color("ffc247")
const SUCCESS := Color("5ad17f")

# --- Terminal-facing defaults (the `cfg_*` colour settings) --------------------
const TERMINAL_FOCUS := Color(0.4, 0.7, 1.0, 0.3)
const SEARCH_HIGHLIGHT := Color(1.0, 0.8, 0.0, 0.35)
const SEARCH_ACTIVE := Color(1.0, 0.5, 0.0, 0.5)
const SCROLLBACK_INDICATOR := Color(1.0, 1.0, 0.0)

# --- Type scale ---------------------------------------------------------------
## The sizes the app already uses: 57 of the 71 font-size literals were 11-12.
const FS_CAPTION := 11
const FS_SMALL := 12
const FS_CONTROL := 13
const FS_BODY := 14
const FS_HEADING := 16
const FS_TITLE := 18
const FS_HERO := 36

# --- Spacing ------------------------------------------------------------------
## The pixel steps already in use, named instead of literal. Same numbers, so
## adopting a token never moves a layout.
const SPACE_HAIR := 1
const SPACE_XS := 2
const SPACE_SM := 4
const SPACE_MD := 6
const SPACE_LG := 8
const SPACE_XL := 12
const SPACE_XXL := 16

## Corner radius on buttons, inputs and popups.
const RADIUS := 3

## `[foreground, background, minimum WCAG ratio, label]` — enforced by the unit
## test. TEXT_DISABLED is absent on purpose: WCAG exempts disabled controls, and
## grading it would force a disabled control to look enabled.
const CONTRAST_PAIRS := [
	[TEXT, BG, 4.5, "text on bg"],
	[TEXT, SURFACE, 4.5, "text on surface"],
	[TEXT, SURFACE_RAISED, 4.5, "text on surface_raised"],
	[TEXT, SIDEBAR, 4.5, "text on sidebar"],
	[TEXT_MUTED, SURFACE, 4.5, "muted on surface"],
	[TEXT_MUTED, SURFACE_RAISED, 4.5, "muted on surface_raised"],
	[TEXT_MUTED, SIDEBAR, 4.5, "muted on sidebar"],
	[ACCENT, SURFACE, 4.5, "accent on surface"],
	[ACCENT, SURFACE_RAISED, 4.5, "accent on surface_raised"],
	[ACCENT, SIDEBAR, 4.5, "accent on sidebar"],
	[ACCENT_HOVER, SURFACE_RAISED, 4.5, "accent_hover on surface_raised"],
	[DANGER, SURFACE, 4.5, "danger on surface"],
	[DANGER, SURFACE_RAISED, 4.5, "danger on surface_raised"],
	[DANGER, SIDEBAR, 4.5, "danger on sidebar"],
	[WARNING, SURFACE_RAISED, 4.5, "warning on surface_raised"],
	[SUCCESS, SURFACE_RAISED, 4.5, "success on surface_raised"],
]

## The WCAG 2.1 contrast ratio of `fg` drawn on `bg`, alpha composited.
##
## The one implementation: the unit test grades `CONTRAST_PAIRS` with it, so a
## measured number in a roadmap row and the test's verdict cannot disagree.
static func contrast_ratio(fg: Color, bg: Color) -> float:
	var lit := bg.lerp(fg, fg.a) if fg.a < 1.0 else fg
	var a := _luminance(lit)
	var b := _luminance(bg)
	if a < b:
		var swap := a
		a = b
		b = swap
	return (a + 0.05) / (b + 0.05)

## Relative luminance per WCAG 2.1, in linearised sRGB.
static func _luminance(c: Color) -> float:
	return 0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b)

static func _channel(v: float) -> float:
	return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)
