class_name WindowChrome
## Titlebar + window-mode handling extracted from workspace.gd.
##
## Owns the custom titlebar, OS window-mode switching, fullscreen toggle,
## and window position persistence. The Workspace keeps `titlebar` for
## layout math and defers all mode changes here.

const HEIGHT = 30.0
const MIN_WINDOW_W = 500
const MIN_WINDOW_H = 300

var titlebar: Control = null
var _ws: Control = null


func build(ws: Control) -> Control:
	_ws = ws
	DisplayServer.window_set_min_size(Vector2i(MIN_WINDOW_W, MIN_WINDOW_H))
	titlebar = Control.new()
	titlebar.name = "GlobalTitleBar"
	titlebar.mouse_filter = Control.MOUSE_FILTER_STOP
	titlebar.anchor_left = 0.0
	titlebar.anchor_right = 1.0
	titlebar.anchor_top = 0.0
	titlebar.offset_top = 0
	titlebar.offset_bottom = HEIGHT

	var bg = ColorRect.new()
	bg.name = "TitleBarBg"
	bg.color = SettingsManager.cfg_title_bar_bg
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	titlebar.add_child(bg)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var label = Label.new()
	label.name = "AppTitle"
	label.text = "gpty"
	label.add_theme_color_override("font_color", Color.WHITE)
	label.anchor_left = 0.0
	label.anchor_right = 0.0
	label.offset_left = 10
	label.offset_right = 200
	label.offset_top = 0
	label.offset_bottom = HEIGHT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	titlebar.add_child(label)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var btn_cont = HBoxContainer.new()
	btn_cont.name = "WinControls"
	btn_cont.anchor_left = 1.0
	btn_cont.anchor_right = 1.0
	btn_cont.offset_left = -120
	btn_cont.offset_right = 0
	btn_cont.offset_top = 0
	btn_cont.offset_bottom = HEIGHT
	btn_cont.alignment = BoxContainer.ALIGNMENT_END

	var min_btn = _make_titlebar_button(Icons.MINIMIZE, func():
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED))
	btn_cont.add_child(min_btn)

	var max_btn = _make_titlebar_button(Icons.MAXIMIZE_WIN, toggle_fullscreen)
	btn_cont.add_child(max_btn)
	titlebar.set_meta("_max_btn", max_btn)

	var close_btn = _make_titlebar_button(Icons.CLOSE, func(): _ws.get_tree().quit())
	btn_cont.add_child(close_btn)

	titlebar.add_child(btn_cont)
	titlebar.gui_input.connect(_on_titlebar_gui_input)

	ws.add_child(titlebar)
	titlebar.visible = false
	return titlebar


func apply_mode():
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	match SettingsManager.cfg_window_mode:
		0:  # Decorated windowed
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			if titlebar: titlebar.visible = false
		1:  # Borderless windowed
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
			if titlebar: titlebar.visible = true
		2:  # Fullscreen (with custom titlebar for mode control)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			if titlebar: titlebar.visible = true
	# Swap titlebar maximize/restore icon
	if titlebar:
		var max_btn = titlebar.get_meta("_max_btn", null)
		if max_btn != null:
			if SettingsManager.cfg_window_mode == 2 and max_btn.text == Icons.MAXIMIZE_WIN:
				max_btn.text = Icons.RESTORE_WIN
			elif SettingsManager.cfg_window_mode != 2 and max_btn.text == Icons.RESTORE_WIN:
				max_btn.text = Icons.MAXIMIZE_WIN
	_ws._apply_layout()


func toggle_fullscreen():
	if SettingsManager.cfg_window_mode == 2:
		SettingsManager.cfg_window_mode = 1
		restore_position()
	else:
		save_position()
		SettingsManager.cfg_window_mode = 2
	apply_mode()
	SettingsManager.save_settings()


func on_window_mode_selected(mode: int):
	if mode == SettingsManager.cfg_window_mode:
		return
	if SettingsManager.cfg_window_mode == 0:
		save_position()
	if mode == 0:
		restore_position()
	SettingsManager.cfg_window_mode = mode
	apply_mode()
	SettingsManager.save_settings()


func save_position():
	if SettingsManager.cfg_window_mode == 0 or SettingsManager.cfg_window_mode == 1:
		SettingsManager.cfg_window_position = DisplayServer.window_get_position()
		SettingsManager.cfg_window_size = DisplayServer.window_get_size()


func restore_position():
	var pos = SettingsManager.cfg_window_position
	var sz = SettingsManager.cfg_window_size
	if pos.x >= 0 and pos.y >= 0:
		DisplayServer.window_set_position(pos)
	if sz.x >= MIN_WINDOW_W and sz.y >= MIN_WINDOW_H:
		DisplayServer.window_set_size(sz)


func _make_titlebar_button(icon: String, callback: Callable) -> Button:
	var btn = Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.custom_minimum_size = Vector2(36, HEIGHT)
	btn.flat = true
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.pressed.connect(callback)
	# Use a Label child for the icon glyph — Button text with theme font
	# overrides doesn't reliably render PUA codepoints in Godot 4.
	var lbl = Label.new()
	lbl.text = icon
	lbl.add_theme_font_override("font", Icons.font_resource)
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(lbl)
	return btn


func _on_titlebar_gui_input(event: InputEvent):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			DisplayServer.window_start_drag()
		elif event.double_click and event.button_index == MOUSE_BUTTON_LEFT:
			toggle_fullscreen()
