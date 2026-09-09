extends Control
class_name ToastOverlay

var _queue: Array[Dictionary] = []
var _active := false
var _toast_count := 0
var _current_label: Label = null
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
	if _current_label:
		_current_label.queue_free()
		_current_label = null
	_active = false

func _show_next():
	if _queue.is_empty():
		_active = false
		return
	_active = true
	var data = _queue.pop_front()
	_toast_count += 1

	var lbl = Label.new()
	lbl.name = "Toast%d" % _toast_count
	lbl.z_index = 100
	lbl.text = data.text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 13)

	match data.level:
		ToastManager.INFO:
			lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
		ToastManager.WARN:
			lbl.add_theme_color_override("font_color", Color.YELLOW)
		ToastManager.ERROR:
			lbl.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))

	add_child(lbl)
	lbl.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	# Float above the status bar (which occupies the window's bottom
	# StatusBar.HEIGHT pixels) or the toast is half-hidden underneath it.
	lbl.offset_top = -(StatusBar.HEIGHT + 44)
	lbl.offset_bottom = -(StatusBar.HEIGHT + 4)

	_current_label = lbl
	var duration: float = data.get("duration", 3.0)
	var t = create_tween()
	_current_tween = t
	t.tween_property(lbl, "modulate:a", 1.0, 0.0).from(0.0)
	t.tween_property(lbl, "modulate:a", 1.0, 0.2).from(0.0)
	t.tween_interval(duration)
	t.tween_property(lbl, "modulate:a", 0.0, 0.5)
	t.tween_callback(func():
		_current_label = null
		_current_tween = null)
	t.tween_callback(lbl.queue_free)
	t.tween_callback(_show_next)
