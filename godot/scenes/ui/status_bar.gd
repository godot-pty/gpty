class_name StatusBar
extends Control
# godopty Status Bar — bottom bar showing pane info, FPS, and window mode.

const HEIGHT = 22.0
const BG_COLOR = Color(0.12, 0.12, 0.14, 1.0)

var _pane_label: Label
var _fps_label: Label
var _mode_label: Label

func _ready():
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(0, HEIGHT)

	var bg = ColorRect.new()
	bg.color = BG_COLOR
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Left — active pane info
	_pane_label = Label.new()
	_pane_label.name = "PaneInfo"
	_pane_label.add_theme_font_size_override("font_size", 11)
	_pane_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_pane_label.anchor_left = 0.0
	_pane_label.offset_left = 8
	_pane_label.offset_top = 2
	_pane_label.text = ""
	add_child(_pane_label)

	# Right — FPS
	_fps_label = Label.new()
	_fps_label.name = "FpsInfo"
	_fps_label.add_theme_font_size_override("font_size", 11)
	_fps_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_fps_label.anchor_left = 1.0
	_fps_label.anchor_right = 1.0
	_fps_label.offset_left = -180
	_fps_label.offset_top = 2
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fps_label.text = ""
	add_child(_fps_label)

	# Right — window mode
	_mode_label = Label.new()
	_mode_label.name = "ModeInfo"
	_mode_label.add_theme_font_size_override("font_size", 11)
	_mode_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_mode_label.anchor_left = 1.0
	_mode_label.anchor_right = 1.0
	_mode_label.offset_left = -48
	_mode_label.offset_top = 2
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_mode_label.text = ""
	add_child(_mode_label)

func set_pane_info(label: String, type_name: String):
	var icon = PaneTypes.ALL.get(type_name, {}).get("icon", "?")
	_pane_label.text = "%s %s  %s" % [icon, label, type_name] if label != "" else ""

func set_fps(fps: int, fetch_ms: int, draw_ms: int):
	var txt = "%d FPS" % fps
	if fetch_ms >= 0:
		txt += "  %d/%dms" % [fetch_ms, draw_ms]
	_fps_label.text = txt

func set_window_mode(mode: int):
	match mode:
		0: _mode_label.text = "OS"
		1: _mode_label.text = "Win"
		2: _mode_label.text = "Full"