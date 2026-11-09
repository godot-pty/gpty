class_name ColorSwatch
## The words a colour swatch needs.
##
## Godot's `ColorPickerButton` draws the engine's alpha checkerboard behind its
## swatch and the colour over it (`scene/gui/color_picker.cpp`,
## `draw_texture_rect(background_icon, r, true)`), so any colour with alpha
## below 1 reads as an unexplained checkerboard: two of the seven Appearance
## rows are translucent by design (`SELECTION` 0.4, `TERMINAL_FOCUS` 0.3) and a
## layout or profile may carry a fully transparent colour into Pane Settings
## (`PaneTypes.TERMINAL_SETTINGS` allows `default_bg`/`default_fg`/`cursor_color`
## from a file). One owner for the reading: the row label names the opacity, the
## tooltip says what the checkerboard is.

## What a fully transparent colour is called in a row label.
const UNSET := "unset"

## At or above this alpha the checkerboard is not visible under the swatch.
const OPAQUE := 0.999

## `""` for an opaque colour, `"40%"` for a translucent one, `UNSET` for none.
static func describe(color: Color) -> String:
	if color.a >= OPAQUE:
		return ""
	if color.a <= 0.0:
		return UNSET
	return "%d%%" % roundi(color.a * 100.0)

## A row's label with the swatch's own reading in brackets — `Selection (40%)`,
## `Default BG (unset)` — and unchanged for an opaque colour.
static func label_text(base: String, color: Color) -> String:
	var reading := describe(color)
	return base if reading == "" else "%s (%s)" % [base, reading]

## The sentence the row carries about its swatch; `""` when nothing needs saying.
static func tooltip(color: Color) -> String:
	match describe(color):
		"":
			return ""
		UNSET:
			return "Unset: this colour is fully transparent, so the swatch shows only the transparency checkerboard and nothing is painted."
		_:
			return "Translucent: the checkerboard behind the swatch is the transparency, so what is underneath shows through."

## Keep `label` reading `picker`'s colour, now and after every change.
## Assigning `color` programmatically does not emit `color_changed`, so a caller
## that assigns must call `sync` itself (the reset buttons do).
static func attach(label: Label, picker: ColorPickerButton) -> void:
	if not label.has_meta(&"base_text"):
		label.set_meta(&"base_text", label.text)
	label.mouse_filter = Control.MOUSE_FILTER_STOP  # a tooltip needs a hover target
	picker.color_changed.connect(func(_c: Color): sync(label, picker))
	sync(label, picker)

static func sync(label: Label, picker: ColorPickerButton) -> void:
	var base := str(label.get_meta(&"base_text", label.text))
	label.text = label_text(base, picker.color)
	label.tooltip_text = tooltip(picker.color)
