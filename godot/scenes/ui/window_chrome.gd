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
## The titlebar's maximize/restore control, which acts as what it says: the
## glyph and the name follow the window mode.
var _max_btn: Button = null
## The three window controls as one keyboard ring; `focus_controls` enters it.
var _controls: HBoxContainer = null


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
	_controls = btn_cont
	btn_cont.anchor_left = 1.0
	btn_cont.anchor_right = 1.0
	btn_cont.offset_left = -120
	btn_cont.offset_right = 0
	btn_cont.offset_top = 0
	btn_cont.offset_bottom = HEIGHT
	btn_cont.alignment = BoxContainer.ALIGNMENT_END

	var min_btn = _make_titlebar_button(Icons.MINIMIZE, func():
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED),
		"Minimize window")
	min_btn.name = "Minimize"
	btn_cont.add_child(min_btn)

	_max_btn = _make_titlebar_button(Icons.MAXIMIZE_WIN, toggle_fullscreen, "Maximize window")
	_max_btn.name = "Maximize"
	btn_cont.add_child(_max_btn)

	var close_btn = _make_titlebar_button(Icons.CLOSE, func(): _ws.request_quit(), "Close window")
	close_btn.name = "Close"
	btn_cont.add_child(close_btn)

	titlebar.add_child(btn_cont)
	titlebar.gui_input.connect(_on_titlebar_gui_input)

	ws.add_child(titlebar)
	# After the bar joins the tree: `ring` stores `get_path_to` results, which
	# are empty for nodes that are not yet in the same tree.
	KeyboardFocus.ring(KeyboardFocus.reachable_children(_controls))
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
	_sync_max_button()
	_ws._apply_layout()


## The maximize control swaps glyph and name with the mode, read from the
## setting rather than from the previous glyph: the glyph is a child Label, so
## comparing `Button.text` (always empty here) was why it never swapped.
func _sync_max_button() -> void:
	if _max_btn == null:
		return
	var fullscreen := SettingsManager.cfg_window_mode == 2
	# The name goes first so `set_glyph` mirrors it onto the glyph Label.
	_max_btn.accessibility_name = "Restore window" if fullscreen else "Maximize window"
	Icons.set_glyph(_max_btn, Icons.RESTORE_WIN if fullscreen else Icons.MAXIMIZE_WIN)

## Move the keyboard into the window's own title bar, the way pane chrome is
## entered. False when the bar is not on screen - the decorated mode hides it -
## or it offers no stop, so the chord that calls this is inert instead of
## focusing something invisible.
func focus_controls() -> bool:
	if titlebar == null or not titlebar.visible or _controls == null:
		return false
	var first := KeyboardFocus.first_reachable(_controls)
	if first == null:
		return false
	first.grab_focus()
	return true


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


## A titlebar control is the shared icon-button treatment at the bar's own
## target size; `Icons.icon_button` draws the glyph in a child Label (Button
## text with theme font overrides does not render PUA codepoints reliably) and
## names it. The size is set first so the bar's 36 px target wins over the
## shared floor.
func _make_titlebar_button(icon: String, callback: Callable, accessible_name: String) -> Button:
	var btn = Button.new()
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.custom_minimum_size = Vector2(36, HEIGHT)
	btn.pressed.connect(callback)
	Icons.icon_button(btn, icon, accessible_name)
	return btn


func _on_titlebar_gui_input(event: InputEvent):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			DisplayServer.window_start_drag()
		elif event.double_click and event.button_index == MOUSE_BUTTON_LEFT:
			toggle_fullscreen()
