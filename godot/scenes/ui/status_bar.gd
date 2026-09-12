class_name StatusBar
extends Control
# gpty Status Bar — bottom bar showing pane info, FPS, clock, and version.

const HEIGHT = 22.0
const BG_COLOR = Color(0.12, 0.12, 0.14, 1.0)

var _pane_label: Label
var _right_label: Label

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

	# Right — combined FPS + clock + version (single label, no layout drift)
	_right_label = Label.new()
	_right_label.name = "RightInfo"
	_right_label.add_theme_font_size_override("font_size", 11)
	_right_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_right_label.anchor_right = 1.0
	_right_label.offset_right = -8
	_right_label.offset_top = 2
	_right_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_right_label.text = ""
	add_child(_right_label)

	var clock_timer = Timer.new()
	clock_timer.name = "ClockTimer"
	clock_timer.wait_time = 1.0
	clock_timer.timeout.connect(_right_update)
	add_child(clock_timer)
	clock_timer.start()

	_version_text = "v" + GptyTerminal.get_app_version()
	_right_update()

func _right_update():
	var t = Time.get_time_dict_from_system()
	_clock_text = "%02d:%02d:%02d" % [t.hour, t.minute, t.second]
	# Clock sits immediately left of the version; the FPS segment is the only
	# one that can still be empty (first frame, before the first sample).
	var parts := PackedStringArray()
	if _fps_text != "":
		parts.append(_fps_text)
	parts.append(_clock_text)
	parts.append(_version_text)
	_right_label.text = "  |  ".join(parts)

var _fps_text: String = ""
var _clock_text: String = ""
var _version_text: String = ""

func set_pane_info(label: String, type_name: String):
	var icon = PaneTypes.ALL.get(type_name, {}).get("icon", "?")
	_pane_label.text = "%s %s  %s" % [icon, label, type_name] if label != "" else ""

func set_fps(fps: int, fetch_ms: int, draw_ms: int):
	_fps_text = "%d FPS" % fps
	if fetch_ms >= 0:
		_fps_text += "  %d/%dms" % [fetch_ms, draw_ms]
	_right_update()