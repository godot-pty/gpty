extends Control
class_name ToastOverlay

var _queue: Array[Dictionary] = []
var _active := false
var _toast_count := 0
var _current_panel: PanelContainer = null
var _current_tween: Tween = null

func _ready():
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	ToastManager.toast_requested.connect(_enqueue)

func _enqueue(data: Dictionary):
	if not data.has("text"): return
	if _active:
		_dismiss_current()
	_queue.append(data)
	_show_next()

func _dismiss_current():
	if _current_tween:
		_current_tween.kill()
		_current_tween = null
	if _current_panel:
		_current_panel.queue_free()
		_current_panel = null
	_active = false

func _show_next():
	if _queue.is_empty():
		_active = false
		return
	_active = true
	var data = _queue.pop_front()
	_toast_count += 1

	# A toast is a message over whatever is running, so it needs a surface of
	# its own (a bare Label was the app's own ink over the terminal's). The
	# level is a 3 px leading edge plus the border, not the ink alone. A toast is
	# a new node per message, which is the case where `accessibility_live`
	# works: the engine publishes a Control's name when its element is created.
	var panel := PanelContainer.new()
	panel.name = "Toast%d" % _toast_count
	panel.z_index = 100
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lbl := Label.new()
	lbl.text = str(data.text)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("font_size", UiTokens.FS_CONTROL)
	lbl.accessibility_name = lbl.text
	lbl.accessibility_live = A11y.LIVE_POLITE
	match data.level:
		ToastManager.WARN:
			panel.theme_type_variation = UiTheme.TOAST_WARN_PANEL
			lbl.theme_type_variation = UiTheme.WARNING_LABEL
		ToastManager.ERROR:
			panel.theme_type_variation = UiTheme.TOAST_ERROR_PANEL
			lbl.theme_type_variation = UiTheme.DANGER_LABEL
		_:
			panel.theme_type_variation = UiTheme.TOAST_PANEL
	panel.add_child(lbl)

	add_child(panel)
	# Grows upward from just above the status bar: equal top/bottom offsets make
	# the content's height the box's height, and the side anchors inset it.
	panel.anchor_left = 0.0; panel.anchor_right = 1.0
	panel.anchor_top = 1.0; panel.anchor_bottom = 1.0
	panel.offset_left = UiTokens.SPACE_XXL
	panel.offset_right = -UiTokens.SPACE_XXL
	panel.offset_top = -(StatusBar.HEIGHT + 4)
	panel.offset_bottom = -(StatusBar.HEIGHT + 4)
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN

	_current_panel = panel
	var duration: float = data.get("duration", 3.0)
	var t = create_tween()
	_current_tween = t
	# One fade-in: the old pair set alpha to 1 instantly and then restarted
	# from 0, so every toast flashed fully opaque for a frame.
	t.tween_property(panel, "modulate:a", 1.0, 0.2).from(0.0)
	t.tween_interval(duration)
	t.tween_property(panel, "modulate:a", 0.0, 0.5)
	t.tween_callback(func():
		_current_panel = null
		_current_tween = null)
	t.tween_callback(panel.queue_free)
	t.tween_callback(_show_next)
