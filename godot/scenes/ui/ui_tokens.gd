class_name UiTokens
## The design tokens that do not change with the mode: the type scale, the
## spacing steps, the corner radius, the layout floor, and the WCAG contrast
## maths.
##
## Colours live in `ui_palette.gd` (`UiPalette`), which carries a complete dark
## and a complete light set and the one active one — read them through
## `UiPalette.active()` at draw time.
##
## `UiPalette.CONTRAST_PAIRS` is the enforced table: a colour used as text on a
## surface belongs in it, and `godot/tests/unit/test_ui_palette.gd` fails the
## build when a pair drops under 4.5:1 in either set. Pure constants and pure
## functions — no scene tree, no autoload — so a canvas or a unit test can use
## them directly.

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

## The floor every icon-only button takes, so a pane title bar's three controls
## and the sidebar's trailing glyphs agree on one target size.
const BUTTON_MIN_WIDTH := 22
const BUTTON_MIN_HEIGHT := 18

# --- Scrollbars ---------------------------------------------------------------
## The scrollbar column in layout pixels: the thumb plus `SCROLLBAR_INSET` on
## each side. 8 px is the engine's own default bar width and the width the
## sidebar's margins were designed around, so the column a `ScrollContainer`
## reserves matches the rest of the chrome. `UiTheme` derives the track's
## content margins and the thumb inset from these numbers, so the bar's
## thickness and its thumb's width cannot disagree.
const SCROLLBAR_THICKNESS := 8
const SCROLLBAR_INSET := 1
## The shortest a thumb may get, so a long transcript's thumb stays a drag
## target instead of a sliver.
const SCROLLBAR_MIN_THUMB := 24

# --- Layout floor --------------------------------------------------------------
## The smallest layout space the chrome is designed for, in layout pixels. The
## Settings card is 540 x 560 and is the largest fixed surface; 540 also leaves
## the 180 px sidebar plus a 2x2 grid of 180 px tiles, the narrowest a pane
## title bar (three 22 px controls and a title) is drawn at. `SettingsManager`
## caps the applied UI scale so the layout never falls under it; the v0.8.3
## small-window work may lower it once the card, the sidebar and the dialogs
## adapt instead of clipping.
const MIN_LAYOUT := Vector2(540, 560)

## The largest whole-percent UI scale a `window_size`-pixel window can show
## without the layout (`window_size / scale`) falling under `MIN_LAYOUT`.
## -1 when the size cannot be measured (a zero or negative axis, as a headless
## display reports): an unmeasurable window must not cap the user's choice.
static func ui_scale_ceiling(window_size: Vector2i) -> int:
	if window_size.x <= 0 or window_size.y <= 0:
		return -1
	var fits := minf(float(window_size.x) / MIN_LAYOUT.x, float(window_size.y) / MIN_LAYOUT.y)
	return int(fits * 100.0)

## The WCAG 2.1 contrast ratio of `fg` drawn on `bg`, alpha composited.
##
## The one implementation: the palette's unit test grades `CONTRAST_PAIRS` with
## it, so a measured number in a roadmap row and the test's verdict cannot
## disagree.
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
