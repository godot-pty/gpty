class_name UiPalette
## The chrome colours in two complete sets, and the one active set.
##
## `UiTokens` owns what does not change with the mode (type scale, spacing,
## radius, the WCAG maths); this module owns every colour. `DARK` and `LIGHT`
## are the source of truth: both carry the same keys, and a token missing from
## one fails `godot/tests/unit/test_ui_palette.gd`.
##
## Read through `active()` **at draw time** — never cache a value in a field, an
## `@export` initializer or an `add_theme_*_override`: the palette switches at
## runtime (`SettingsManager.apply_appearance()`), and a cached copy keeps the
## mode it was built under. A widget that needs a colour its type's default does
## not carry names a `Theme` type variation (`UiTheme.MUTED_LABEL`, …) instead.

const MODE_DARK := 0
const MODE_LIGHT := 1

## `token -> Color`. Both tables carry the same keys. The five terminal-facing
## entries are equal in both on purpose: they are drawn over the terminal's own
## scheme, which is chosen independently of the chrome, and the scheme pair
## lands with the colour-scheme row.
const DARK := {
	"BG": Color("1a1a1a"),
	"SURFACE": Color("202128"),
	"SURFACE_RAISED": Color("2e2e33"),
	"SIDEBAR": Color("1f1f26"),
	"BORDER": Color("3a3d46"),
	"SELECTION": Color(0.3, 0.5, 1.0, 0.4),
	"TEXT": Color("e6e8ec"),
	"TEXT_MUTED": Color("9aa0aa"),
	"TEXT_DISABLED": Color("767b85"),
	"ACCENT": Color("7fb4ff"),
	"ACCENT_HOVER": Color("a6c9ff"),
	"DANGER": Color("ff8080"),
	"WARNING": Color("ffc247"),
	"SUCCESS": Color("5ad17f"),
	"TERMINAL_FOCUS": Color(0.4, 0.7, 1.0, 0.3),
	"SEARCH_HIGHLIGHT": Color(1.0, 0.8, 0.0, 0.35),
	"SEARCH_ACTIVE": Color(1.0, 0.5, 0.0, 0.5),
	"SCROLLBACK_INDICATOR": Color(1.0, 1.0, 0.0),
}

const LIGHT := {
	"BG": Color("f5f5f7"),
	"SURFACE": Color("ffffff"),
	"SURFACE_RAISED": Color("e6e7ec"),
	"SIDEBAR": Color("eeeef3"),
	"BORDER": Color("c3c6cf"),
	"SELECTION": Color(0.3, 0.5, 1.0, 0.4),
	"TEXT": Color("1b1e24"),
	"TEXT_MUTED": Color("525a68"),
	"TEXT_DISABLED": Color("8b909c"),
	"ACCENT": Color("1a5fb4"),
	"ACCENT_HOVER": Color("0f4a93"),
	"DANGER": Color("b3261e"),
	"WARNING": Color("8a5a00"),
	"SUCCESS": Color("1c6b3c"),
	"TERMINAL_FOCUS": Color(0.4, 0.7, 1.0, 0.3),
	"SEARCH_HIGHLIGHT": Color(1.0, 0.8, 0.0, 0.35),
	"SEARCH_ACTIVE": Color(1.0, 0.5, 0.0, 0.5),
	"SCROLLBACK_INDICATOR": Color(1.0, 1.0, 0.0),
}

## `[foreground token, background token, minimum WCAG ratio, label]`, graded
## against both sets by the unit test. TEXT_DISABLED is absent on purpose: WCAG
## exempts disabled controls, and grading it would force a disabled control to
## look enabled.
const CONTRAST_PAIRS := [
	["TEXT", "BG", 4.5, "text on bg"],
	["TEXT", "SURFACE", 4.5, "text on surface"],
	["TEXT", "SURFACE_RAISED", 4.5, "text on surface_raised"],
	["TEXT", "SIDEBAR", 4.5, "text on sidebar"],
	["TEXT_MUTED", "SURFACE", 4.5, "muted on surface"],
	["TEXT_MUTED", "SURFACE_RAISED", 4.5, "muted on surface_raised"],
	["TEXT_MUTED", "SIDEBAR", 4.5, "muted on sidebar"],
	["ACCENT", "SURFACE", 4.5, "accent on surface"],
	["ACCENT", "SURFACE_RAISED", 4.5, "accent on surface_raised"],
	["ACCENT", "SIDEBAR", 4.5, "accent on sidebar"],
	["ACCENT_HOVER", "SURFACE_RAISED", 4.5, "accent_hover on surface_raised"],
	["DANGER", "SURFACE", 4.5, "danger on surface"],
	["DANGER", "SURFACE_RAISED", 4.5, "danger on surface_raised"],
	["DANGER", "SIDEBAR", 4.5, "danger on sidebar"],
	["WARNING", "SURFACE_RAISED", 4.5, "warning on surface_raised"],
	["SUCCESS", "SURFACE_RAISED", 4.5, "success on surface_raised"],
]

# --- One value per token ------------------------------------------------------
# Declared fields, not a bare dictionary, so every read site is compile-checked
# and the editor can complete it. `_init` fills them from the chosen table.

var BG: Color
var SURFACE: Color
var SURFACE_RAISED: Color
var SIDEBAR: Color
var BORDER: Color
var SELECTION: Color
var TEXT: Color
var TEXT_MUTED: Color
var TEXT_DISABLED: Color
var ACCENT: Color
var ACCENT_HOVER: Color
var DANGER: Color
var WARNING: Color
var SUCCESS: Color
var TERMINAL_FOCUS: Color
var SEARCH_HIGHLIGHT: Color
var SEARCH_ACTIVE: Color
var SCROLLBACK_INDICATOR: Color

func _init(values: Dictionary = DARK) -> void:
	for token in values:
		set(token, values[token])

## A token's colour, for a caller whose token name is data (`SettingsManager`'s
## chrome-colour table, a badge role, a contrast pair). `TRANSPARENT` for a name
## this set does not carry — the unit test makes that unreachable.
func color(token: String) -> Color:
	var v = get(token)
	return v if v is Color else Color.TRANSPARENT

# --- The active set -----------------------------------------------------------
# Lazy, because a static initialiser that names its own class is a parse-time
# cycle.

static var _mode: int = MODE_DARK
static var _dark: UiPalette = null
static var _light: UiPalette = null

static func dark() -> UiPalette:
	if _dark == null:
		_dark = UiPalette.new(DARK)
	return _dark

static func light() -> UiPalette:
	if _light == null:
		_light = UiPalette.new(LIGHT)
	return _light

## Select the set every later `active()` read returns.
static func use(mode: int) -> void:
	_mode = MODE_LIGHT if mode == MODE_LIGHT else MODE_DARK

static func mode() -> int:
	return _mode

## The active set, never null: a reader that runs before `use()` (a test, a
## tool) gets the dark set.
static func active() -> UiPalette:
	return light() if _mode == MODE_LIGHT else dark()
