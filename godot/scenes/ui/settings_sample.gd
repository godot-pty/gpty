class_name SettingsSample
extends Control
## The one sample pane mock the Settings previews use. It is a scratch Control,
## never a `PaneBody`: it draws a terminal ground, a few scheme-coloured runs,
## an inverse cell and an underline, and carries the ambient/cue effect layers
## that the shipped `PaneEffects` paints.
##
## Two effects layers, because a pane has two:
##  - `EffectSurface` (`EffectSurface`, behind the sample's own draw) paints the
##    ambient ground shader;
##  - `CueLayer` (a `PaneEffects` child drawn after the text) plays a reactive
##    cue above the text exactly as a pane's overlay does.
##
## The sample reads the scheme it is handed and the palette at draw time; it
## never caches `UiPalette.active()` in a field, so a theme switch reaches the
## next frame.

const TEXT_INSET := 8.0

var _scheme: Dictionary = {}
var _font: Font = null
var _font_px := 12
var _effect: EffectSurface = null
var _cue: PaneEffects = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_ALL
	_ensure_layers()
	resized.connect(queue_redraw)

func _ensure_layers() -> void:
	if _effect == null:
		_effect = EffectSurface.new()
		_effect.name = "EffectSurface"
		_effect.show_behind_parent = true
		add_child(_effect)
		_effect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if _cue == null:
		_cue = PaneEffects.new()
		_cue.name = "CueLayer"
		_cue.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_cue.focus_mode = Control.FOCUS_NONE
		add_child(_cue)
		_cue.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func set_style(scheme: Dictionary, font: Font, font_px: int) -> void:
	_scheme = scheme
	_font = font
	_font_px = maxi(1, font_px)
	queue_redraw()

func effect_surface() -> EffectSurface:
	_ensure_layers()
	return _effect

func cue_layer() -> PaneEffects:
	_ensure_layers()
	return _cue

func _draw() -> void:
	if size.x < 4.0 or size.y < 4.0:
		return
	var p := UiPalette.active()
	var ground := SchemeLibrary.color(_scheme, "background", Color.BLACK)
	if _effect == null or not _effect.wants_backdrop():
		draw_rect(Rect2(Vector2.ZERO, size), ground)
	draw_rect(Rect2(Vector2(0.5, 0.5), size - Vector2.ONE), p.BORDER, false, 1.0)
	if _font == null:
		_draw_focus_ring(p)
		return

	var fg := SchemeLibrary.color(_scheme, "foreground", Color8(229, 229, 229))
	var red := _palette_color(1, Color8(255, 85, 85))
	var green := _palette_color(2, Color8(80, 220, 120))
	var ascent := _font.get_ascent(_font_px)
	var line := float(_font_px) + 6.0
	var x := TEXT_INSET
	var y := TEXT_INSET + ascent

	draw_string(_font, Vector2(x, y), "$ gpty status",
		HORIZONTAL_ALIGNMENT_LEFT, -1, _font_px, fg)
	y += line
	var fail := "FAIL"
	draw_string(_font, Vector2(x, y), fail,
		HORIZONTAL_ALIGNMENT_LEFT, -1, _font_px, red)
	var fail_w := _font.get_string_size(fail, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_px).x
	draw_string(_font, Vector2(x + fail_w + 6.0, y), "ok",
		HORIZONTAL_ALIGNMENT_LEFT, -1, _font_px, green)

	y += line
	var inverse := "INVERSE"
	var inverse_w := _font.get_string_size(inverse, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_px).x
	var cell := Rect2(Vector2(x, y - ascent - 1.0),
		Vector2(inverse_w + 4.0, _font.get_height(_font_px) + 2.0))
	draw_rect(cell, fg)
	draw_string(_font, Vector2(x + 2.0, y), inverse,
		HORIZONTAL_ALIGNMENT_LEFT, -1, _font_px, ground)

	var link_x := x + inverse_w + 14.0
	var link := "link"
	draw_string(_font, Vector2(link_x, y), link,
		HORIZONTAL_ALIGNMENT_LEFT, -1, _font_px, p.ACCENT)
	var link_w := _font.get_string_size(link, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_px).x
	draw_line(Vector2(link_x, y + 2.0), Vector2(link_x + link_w, y + 2.0), p.ACCENT, 1.0)
	_draw_focus_ring(p)

func _draw_focus_ring(p) -> void:
	if has_focus():
		draw_rect(Rect2(Vector2(0.5, 0.5), size - Vector2.ONE), p.ACCENT, false, 1.0)

## One ANSI slot from the scheme's 16-colour palette, or the fallback when the
## scheme carries none (the built-in terminal palette is not a file).
func _palette_color(index: int, fallback: Color) -> Color:
	var palette = _scheme.get("palette", [])
	if not (palette is Array) or index >= (palette as Array).size():
		return fallback
	return Color.from_string(str((palette as Array)[index]), fallback)
