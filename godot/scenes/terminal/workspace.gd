extends Control
class_name Workspace
# gpty Workspace — tiling grid of panes with title bars.
# Tile lifecycle is delegated to TerminalManager.

const GRID = 12
const MIN_WINDOW_W = 500
const MIN_WINDOW_H = 300
const TITLEBAR_HEIGHT = 30.0

static func _build_palette_commands() -> Array[String]:
	var cmds: Array[String] = []
	for key in PaneTypes.ALL:
		cmds.append("new " + PaneTypes.ALL[key]["name"].to_lower())
	cmds.append_array(["close active", "spawn 16 terminals", "settings", "reset layout", "save", "load"])
	return cmds

var _sidebar: Sidebar
var _sidebar_bg: ColorRect
var _palette: Control
var _grid: Control
var _settings_panel: SettingsPanel
var _tm: TerminalManager = TerminalManager.new()
var _status_bar: StatusBar
var _titlebar: Control = null

func _ready():
	show()
	_build_titlebar()
	DisplayServer.window_set_min_size(Vector2i(MIN_WINDOW_W, MIN_WINDOW_H))

	_grid = Control.new()
	add_child(_grid)

	var overlay = load("res://scenes/ui/toast_overlay.gd").new()
	add_child(overlay)

	var pane_settings = load("res://scenes/ui/pane_settings_panel.gd").new()
	add_child(pane_settings)
	_tm._pane_settings_panel = pane_settings

	_build_sidebar()

	_status_bar = StatusBar.new()
	_status_bar.name = "StatusBar"
	add_child(_status_bar)

	ProfileManager.load_profiles()
	_wire_sidebar_signals()
	_refresh_profile_buttons()
	_tm.on_close = func(body: Control): _kill(body)
	_tm.on_swap = _swap_pane
	_restore(); _sync_pane_titlebars(); if _tm.tiles.is_empty(): _spawn_pane("terminal")

	# Per-type keyboard shortcuts
	for key in PaneTypes.ALL:
		var info = PaneTypes.ALL[key]
		ShortcutManager.register("app:new_" + key, info["shortcut"], func(): var b = _spawn_pane(key); if b: b.grab_focus())
	ShortcutManager.register("app:close_pane", "Ctrl+Shift+W", func(): _kill_last())
	ShortcutManager.register("app:toggle_sidebar", "Ctrl+Shift+B", _toggle_sidebar)
	ShortcutManager.register("app:toggle_palette", "Ctrl+Shift+P", _toggle_palette)
	ShortcutManager.register("app:toggle_fullscreen", "F11", _toggle_fullscreen)
	ShortcutManager.register("app:toggle_fullscreen_alt", "Ctrl+Shift+M", _toggle_fullscreen)
	ShortcutManager.register("app:reset_workspace", "Ctrl+Shift+R", func():
		_reset(); _apply_layout(); _list()
	)

	SettingsManager.settings_changed.connect(_on_settings_changed)
	_on_settings_changed()
	_apply_window_mode.call_deferred()
	if SettingsManager.cfg_window_mode == 0: _restore_window_position()

func _on_settings_changed():
	for t in _tm.tiles:
		var body = _tm._find_body(t.wrapper)
		if body and body is TerminalPane:
			SettingsManager.apply_to_terminal(body)
	_sync_pane_titlebars()
	_apply_fps_setting()
	_apply_window_mode()

func _sync_pane_titlebars():
	for t in _tm.tiles:
		var tb = t.wrapper.get_node_or_null("BodyVBox/TitleBar")
		if tb: tb.visible = SettingsManager.cfg_show_titlebar

func _apply_fps_setting():
	if SettingsManager.cfg_max_fps == -1:
		var rr = DisplayServer.screen_get_refresh_rate()
		Engine.max_fps = int(rr) if rr > 0 else 0
	else:
		Engine.max_fps = SettingsManager.cfg_max_fps

func _notification(what):
	if what == NOTIFICATION_RESIZED: _apply_layout()
	if what == NOTIFICATION_WM_CLOSE_REQUEST: _save_window_position()

# NOTE: We save in _exit_tree(), not NOTIFICATION_WM_CLOSE_REQUEST.
# WM_CLOSE_REQUEST does not fire when the Godot editor stops the game,
# only on actual window close in standalone builds. _exit_tree() fires
# reliably whenever the scene tree is torn down.

func _exit_tree():
	_save_window_position()
	_save()
	SettingsManager.save_settings()

func _apply_window_mode():
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	match SettingsManager.cfg_window_mode:
		0:  # Decorated windowed
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			if _titlebar: _titlebar.visible = false
		1:  # Borderless windowed
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
			if _titlebar: _titlebar.visible = true
		2:  # Fullscreen (with custom titlebar for mode control)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			if _titlebar: _titlebar.visible = true
	# Swap titlebar maximize/restore icon
	if _titlebar:
		var max_btn = _titlebar.get_meta("_max_btn", null)
		if max_btn != null:
			if SettingsManager.cfg_window_mode == 2 and max_btn.text == Icons.MAXIMIZE_WIN:
				max_btn.text = Icons.RESTORE_WIN
			elif SettingsManager.cfg_window_mode != 2 and max_btn.text == Icons.RESTORE_WIN:
				max_btn.text = Icons.MAXIMIZE_WIN
	_apply_layout()
func _toggle_fullscreen():
	if SettingsManager.cfg_window_mode == 2:
		SettingsManager.cfg_window_mode = 1
		_restore_window_position()
	else:
		_save_window_position()
		SettingsManager.cfg_window_mode = 2
	_apply_window_mode()
	SettingsManager.save_settings()

func _on_window_mode_selected(mode: int):
	if mode == SettingsManager.cfg_window_mode:
		return
	if SettingsManager.cfg_window_mode == 0:
		_save_window_position()
	if mode == 0:
		_restore_window_position()
	SettingsManager.cfg_window_mode = mode
	_apply_window_mode()
	SettingsManager.save_settings()

func _save_window_position():
	if SettingsManager.cfg_window_mode == 0 or SettingsManager.cfg_window_mode == 1:
		SettingsManager.cfg_window_position = DisplayServer.window_get_position()
		SettingsManager.cfg_window_size = DisplayServer.window_get_size()

func _restore_window_position():
	var pos = SettingsManager.cfg_window_position
	var sz = SettingsManager.cfg_window_size
	if pos.x >= 0 and pos.y >= 0:
		DisplayServer.window_set_position(pos)
	if sz.x >= MIN_WINDOW_W and sz.y >= MIN_WINDOW_H:
		DisplayServer.window_set_size(sz)
func _build_titlebar():
	_titlebar = Control.new()
	_titlebar.name = "GlobalTitleBar"
	_titlebar.mouse_filter = Control.MOUSE_FILTER_STOP
	_titlebar.anchor_left = 0.0
	_titlebar.anchor_right = 1.0
	_titlebar.anchor_top = 0.0
	_titlebar.offset_top = 0
	_titlebar.offset_bottom = TITLEBAR_HEIGHT

	var bg = ColorRect.new()
	bg.name = "TitleBarBg"
	bg.color = SettingsManager.cfg_title_bar_bg
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_titlebar.add_child(bg)
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
	label.offset_bottom = TITLEBAR_HEIGHT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_titlebar.add_child(label)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var btn_cont = HBoxContainer.new()
	btn_cont.name = "WinControls"
	btn_cont.anchor_left = 1.0
	btn_cont.anchor_right = 1.0
	btn_cont.offset_left = -120
	btn_cont.offset_right = 0
	btn_cont.offset_top = 0
	btn_cont.offset_bottom = TITLEBAR_HEIGHT
	btn_cont.alignment = BoxContainer.ALIGNMENT_END

	var min_btn = _make_titlebar_button(Icons.MINIMIZE, func():
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED))
	btn_cont.add_child(min_btn)

	var max_btn = _make_titlebar_button(Icons.MAXIMIZE_WIN, _toggle_fullscreen)
	btn_cont.add_child(max_btn)
	_titlebar.set_meta("_max_btn", max_btn)

	var close_btn = _make_titlebar_button(Icons.CLOSE, func(): get_tree().quit())
	btn_cont.add_child(close_btn)

	_titlebar.add_child(btn_cont)
	_titlebar.gui_input.connect(_on_titlebar_gui_input)

	add_child(_titlebar)
	_titlebar.visible = false

func _make_titlebar_button(icon: String, callback: Callable) -> Button:
	var btn = Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.custom_minimum_size = Vector2(36, TITLEBAR_HEIGHT)
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
			_toggle_fullscreen()
# ═══════════════════════════════════════════════════════════════════════
# Layout
# ═══════════════════════════════════════════════════════════════════════

func _apply_layout():
	if _grid == null: return
	var top_offset = TITLEBAR_HEIGHT if (_titlebar and _titlebar.visible) else 0.0
	var bottom_offset = StatusBar.HEIGHT if _status_bar else 0.0
	var m = _sidebar_bg.size.x if (_sidebar_bg and _sidebar_bg.visible) else 0.0
	_grid.offset_left = m; _grid.offset_right = 0
	_grid.offset_top = top_offset; _grid.offset_bottom = -bottom_offset
	_grid.anchor_left = 0.0; _grid.anchor_right = 1.0
	_grid.anchor_top = 0.0; _grid.anchor_bottom = 1.0

	if _status_bar:
		_status_bar.anchor_left = 0.0; _status_bar.anchor_right = 1.0
		_status_bar.anchor_top = 1.0; _status_bar.anchor_bottom = 1.0
		_status_bar.offset_top = -StatusBar.HEIGHT; _status_bar.offset_bottom = 0

	var cw = maxf(_grid.size.x, 1.0) / GRID
	var ch = maxf(_grid.size.y, 1.0) / GRID
	for t in _tm.tiles:
		var x = t.col * cw; var y = t.row * ch
		var w = t.cspan * cw; var h = t.rspan * ch
		t.wrapper.offset_left = x; t.wrapper.offset_top = y
		t.wrapper.offset_right = x + w; t.wrapper.offset_bottom = y + h
		t.wrapper.anchor_left = 0.0; t.wrapper.anchor_right = 0.0
		t.wrapper.anchor_top = 0.0; t.wrapper.anchor_bottom = 0.0

# ═══════════════════════════════════════════════════════════════════════
# Spawn / Kill — delegate to TerminalManager
# ═══════════════════════════════════════════════════════════════════════

func _spawn(shell := "") -> Control:
	return _spawn_pane("terminal", {"shell_command": shell})

func _spawn_pane(type_name: String, opts := {}) -> Control:
	var body = _tm.spawn_pane(type_name, opts)
	if body == null:
		ToastManager.warn("Cannot add pane — grid is full")
		return null
	var w = _tm.tiles[-1].wrapper
	_add_body_to_grid(w, body, PaneTypes.ALL[type_name]["name"])
	return body

func _add_body_to_grid(w: Control, body: Control, label: String):
	_grid.add_child(w)
	body.focus_entered.connect(func(): _tm.last_body = body)
	_apply_layout()
	_list()
	ToastManager.info("%s spawned" % label)

func _spawn_bulk(count: int, shell := ""):
	var start_size = _tm.tiles.size()
	var bodies = _tm.spawn_bulk(count, shell)
	if bodies.is_empty():
		ToastManager.warn("Cannot add terminals — grid is full")
		return
	for i in bodies.size():
		var w = _tm.tiles[start_size + i].wrapper
		var body = bodies[i]
		_grid.add_child(w)
		body.focus_entered.connect(func(): _tm.last_body = body)
	_apply_layout()
	_list()
	ToastManager.info("Spawned %d terminals" % bodies.size())
	if bodies.size() > 0: bodies[-1].grab_focus()

func _kill(body: Control):
	_tm.kill(body)
	_apply_layout()
	_list()
	ToastManager.info("Pane closed")

func _swap_pane(body: Control, new_type_name: String):
	var old_wrapper = null
	for t in _tm.tiles:
		if _tm._find_body(t.wrapper) == body:
			old_wrapper = t.wrapper
			break

	var new_body = _tm.swap_pane(body, new_type_name)
	if new_body == null: return

	# Find the new wrapper (tile's wrapper was replaced in-place)
	var new_wrapper = null
	for t in _tm.tiles:
		if _tm._find_body(t.wrapper) == new_body:
			new_wrapper = t.wrapper
			break

	# Remove old wrapper from grid, add new one.
	if old_wrapper:
		_grid.remove_child(old_wrapper)
	if new_wrapper:
		_grid.add_child(new_wrapper)

	# Wire signals (same pattern as _add_body_to_grid).
	new_body.focus_entered.connect(func(): _tm.last_body = new_body)

	# For terminals: apply global defaults and wire dynamic title.
	if new_type_name == "terminal":
		if new_body.has_method("_terminal"):
			SettingsManager.apply_to_terminal(new_body)
		new_body.title_changed.connect(func(t: String):
			var lbl = new_wrapper.get_node_or_null("BodyVBox/TitleBar/TitleLabel")
			if lbl: lbl.text = " " + t
		)

	_apply_layout()
	_list()
	if new_body.focus_mode != Control.FOCUS_NONE:
		new_body.grab_focus()
	ToastManager.info("Swapped to %s" % PaneTypes.ALL[new_type_name]["name"])

func _kill_last():
	_tm.kill_last()
	_apply_layout()
	_list()

func _on_pane_minimize(body: Control):
	body.visible = not body.visible
	_apply_layout()
	_list()  # refresh sidebar to update minimize icon

func _on_pane_position_swap(body: Control, source_btn: Button):
	_tm.show_position_swap_popup(body, self, source_btn.get_screen_position() + Vector2(0, source_btn.size.y))

func _on_pane_type_swap(body: Control, source_btn: Button):
	_tm.show_type_swap_popup(body, self, source_btn.get_screen_position() + Vector2(0, source_btn.size.y))

func _reset():
	_tm.reset()
	_apply_layout()
	_list()

# ═══════════════════════════════════════════════════════════════════════
# Persistence
# ═══════════════════════════════════════════════════════════════════════

func _gather_tiles() -> Array[Dictionary]:
	var ts: Array[Dictionary] = []
	for t in _tm.tiles:
		var body = _tm._find_body(t.wrapper)
		var settings = body._get_layout_state() if body and body.has_method("_get_layout_state") else {}
		ts.append({
			"col": t.col, "row": t.row,
			"cspan": t.cspan, "rspan": t.rspan,
			"settings": settings,
		})
	return ts

func _save():
	LayoutManager.save_tiles(_gather_tiles())

func _restore():
	var tiles = LayoutManager.load_tiles()
	if tiles.is_empty(): return

	# Workspace trust: warn if saved shells differ from configured default
	var untrusted := false
	for td in tiles:
		if not (td is Dictionary): continue
		var settings = td.get("settings", {})
		var sh = settings.get("shell", td.get("shell", ""))
		if sh != "" and sh != SettingsManager.cfg_shell_command:
			untrusted = true
			break
	if untrusted:
		_show_trust_dialog(tiles)
		return
	_do_restore(tiles)

func _show_trust_dialog(tiles: Array[Dictionary]):
	var dialog = ConfirmationDialog.new()
	dialog.title = "Workspace Trust"
	dialog.dialog_text = "This layout was saved with a different shell than your current default (%s).\n\nDo you want to restore it anyway?" % SettingsManager.cfg_shell_command
	dialog.ok_button_text = "Restore"
	dialog.cancel_button_text = "Cancel"
	dialog.confirmed.connect(func(): _do_restore(tiles); dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()

func _do_restore(tiles: Array[Dictionary]):
	_tm.reset()
	for td in tiles:
		if not (td is Dictionary): continue
		var settings = td.get("settings", {})
		var type_name = settings.get("type", "terminal")

		var body = _tm.create_body(type_name)
		if body == null: continue
		body.apply_settings(settings)

		# For terminals: apply global defaults and shell override
		if type_name == "terminal":
			var sh = settings.get("shell", td.get("shell", SettingsManager.cfg_shell_command))
			if sh == null or sh == "": sh = SettingsManager.cfg_shell_command
			SettingsManager.apply_to_terminal(body)
			body.shell_command = sh

		var title = PaneTypes.ALL.get(type_name, {}).get("name", type_name)
		var w = _tm._build_wrapper_body(body, title)

		if type_name == "terminal":
			body.title_changed.connect(func(t: String):
				var lbl = w.get_node_or_null("BodyVBox/TitleBar/TitleLabel")
				if lbl: lbl.text = " " + t
			)

		_grid.add_child(w)
		body.focus_entered.connect(func(): _tm.last_body = body)
		_tm.tiles.append({wrapper = w, col = td.get("col", 0), row = td.get("row", 0),
			cspan = td.get("cspan", GRID), rspan = td.get("rspan", GRID)})
	_apply_layout(); _list()

# ═══════════════════════════════════════════════════════════════════════
# Palette
# ═══════════════════════════════════════════════════════════════════════

func _unhandled_input(event):
	if _palette and _palette.visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_palette.visible = false
		get_viewport().set_input_as_handled()

func _toggle_palette():
	if _palette == null:
		_palette = _build_palette()
		add_child(_palette)
		_palette.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_palette.visible = not _palette.visible
	if _palette.visible:
		var inp = _palette.find_child("*", true, false) as LineEdit
		if inp: inp.grab_focus()


func _build_palette() -> Control:
	var bg = Panel.new()
	bg.custom_minimum_size = Vector2(320, 160)
	bg.name = "Palette"
	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	bg.add_child(v)
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var mc = MarginContainer.new()
	mc.add_theme_constant_override("margin_left", 8)
	mc.add_theme_constant_override("margin_right", 8)
	mc.add_theme_constant_override("margin_top", 8)
	mc.add_theme_constant_override("margin_bottom", 8)
	v.add_child(mc)
	var inp = LineEdit.new()
	inp.placeholder_text = "Type command..."
	inp.add_theme_font_size_override("font_size", 14)
	mc.add_child(inp)
	var results = VBoxContainer.new()
	v.add_child(results)

	var cmds = _build_palette_commands()
	inp.text_changed.connect(func(t: String):
		for c in results.get_children(): c.queue_free()
		for cmd in cmds:
			if t == "" or cmd.findn(t) != -1:
				var btn = Button.new()
				btn.text = cmd; btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
				btn.add_theme_font_size_override("font_size", 13)
				btn.pressed.connect(func():
					_execute_command(cmd); _palette.visible = false
				)
				results.add_child(btn)
	)

	inp.text_submitted.connect(func(_t: String):
		if results.get_child_count() > 0:
			(results.get_child(0) as Button).pressed.emit()
	)

	return bg

func _execute_command(cmd: String):
	if cmd.begins_with("new "):
		var type_label = cmd.substr(4).strip_edges()
		for key in PaneTypes.ALL:
			if PaneTypes.ALL[key]["name"].to_lower() == type_label:
				var body = _spawn_pane(key)
				if body: body.grab_focus()
				return
		return
	match cmd:
		"close active": _kill_last()
		"spawn 16 terminals": _spawn_bulk(16)
		"settings": _toggle_settings()
		"reset layout": _reset()
		"save": _save()
		"load": _restore()

# ═══════════════════════════════════════════════════════════════════════
# Sidebar
# ═══════════════════════════════════════════════════════════════════════


# ── Sidebar ───────────────────────────────────────────────────────────

func _wire_sidebar_signals():
	_sidebar.request_new_pane.connect(_spawn_pane)
	_sidebar.request_close.connect(func(body: Control): _kill(body))
	_sidebar.request_settings.connect(_toggle_settings)
	_sidebar.request_reset.connect(func(): _reset(); _apply_layout(); _list())
	_sidebar.request_focus.connect(func(body: Control): body.grab_focus())
	_sidebar.request_minimize.connect(func(body: Control): _on_pane_minimize(body))
	_sidebar.request_position_swap.connect(func(body: Control, btn: Button): _on_pane_position_swap(body, btn))
	_sidebar.request_type_swap.connect(func(body: Control, btn: Button): _on_pane_type_swap(body, btn))
	_sidebar.request_pane_settings.connect(func(body: Control): _tm._open_pane_settings(body))
	_sidebar.toggled.connect(func(): _on_sidebar_toggled())
	_sidebar.request_profile.connect(_activate_profile)
	_sidebar.request_window_mode.connect(_on_window_mode_selected)
	_sidebar.request_save_profile.connect(_save_current_as_profile)
	_sidebar.request_delete_profile.connect(_delete_profile)
	_tm.tiles_resized.connect(_apply_layout)
	ProfileManager.profiles_changed.connect(_refresh_profile_buttons)

func _list():
	if _sidebar == null: return
	var panes: Array[Control] = []
	for t in _tm.tiles:
		var body = _tm._find_body(t.wrapper)
		if body: panes.append(body)
	_sidebar.update_pane_list(panes)

func _toggle_sidebar():
	if _sidebar: _sidebar._toggle_sidebar()

func _on_sidebar_toggled():
	# Sync background rect to sidebar's new width
	_sidebar_bg.offset_right = _sidebar.offset_right
	# Show titlebar label only when sidebar is expanded
	if _titlebar:
		var lbl = _titlebar.get_node_or_null("AppTitle")
		if lbl: lbl.visible = _sidebar.offset_right > 50
	_apply_layout()

func _process(_delta: float):
	# Concept event polling — must run even before sidebar is ready
	_poll_concept_events()
	_poll_ipc_requests()
	if _sidebar == null: return
	# FPS counter update (throttled to ~4 Hz)
	if Engine.get_process_frames() % 15 == 0:
		var fps = Engine.get_frames_per_second()
		var body = _tm.last_body
		var fetch_ms = -1; var draw_ms = -1
		if body and body.has_method("_draw"):
			fetch_ms = body.get("_fetch_ms") if "_fetch_ms" in body else -1
			draw_ms = body.get("_draw_ms") if "_draw_ms" in body else -1
		if _status_bar:
			_status_bar.set_fps(fps, fetch_ms, draw_ms)
	_refresh_status_bar()

func _refresh_status_bar():
	if _status_bar == null: return
	var body = _tm.last_body
	if body:
		_status_bar.set_pane_info(body.pane_label, body._pane_type())
	else:
		_status_bar.set_pane_info("", "")
	_status_bar.set_window_mode(SettingsManager.cfg_window_mode)
# ═══════════════════════════════════════════════════════════════════════
# Concept event routing
# ═══════════════════════════════════════════════════════════════════════

func _poll_concept_events():
	for t in _tm.tiles:
		var body = _tm._find_body(t.wrapper)
		if not body or not body is TerminalPane:
			continue
		var term = body.get("_terminal")
		if term == null:
			continue
		var events = term.drain_concept_events()
		for ev in events:
			if not (ev is Dictionary):
				continue
			route_concept_event(term, ev)

func route_concept_event(source_term, ev: Dictionary):
	var target_type: String = ev.get("target_pane_type", "")
	var receiver = _find_pane_of_type(target_type)
	if receiver and receiver.has_method("receive_content"):
		var lines: PackedStringArray = ev.get("lines", PackedStringArray())
		receiver.receive_content("\n".join(lines))
		source_term.acknowledge_capture(ev.get("id", 0))
	else:
		ToastManager.warn("No %s pane open for '%s' output" % [target_type, ev.get("concept_name", "")])
		source_term.flush_capture(ev.get("id", 0))

func _find_pane_of_type(type_name: String) -> Control:
	for t in _tm.tiles:
		var body = _tm._find_body(t.wrapper)
		if body and body._pane_type() == type_name:
			return body
	return null

# ═══════════════════════════════════════════════════════════════════════
# IPC bridge — polls Rust IPC requests from _process
# ═══════════════════════════════════════════════════════════════════════

func _poll_ipc_requests():
	# GodoptyTerminal is a GodotClass — call static methods on the class
	var reqs = GodoptyTerminal.drain_ipc_requests()
	if reqs.is_empty():
		return
	for req in reqs:
		var id = req["id"]
		var method = req["method"]
		var params_str = req["params"]
		var params = {}
		if params_str != "":
			params = JSON.parse_string(params_str)
			if params == null:
				params = {}
		var result = _handle_ipc_method(method, params)
		var success = not (result is Dictionary and result.has("error"))
		var result_json = JSON.stringify(result) if typeof(result) != TYPE_STRING else result
		GodoptyTerminal.respond_ipc(id, success, result_json)

func _handle_ipc_method(method: String, params):
	match method:
		"newPane":
			var type_name = str(params.get("type", "terminal"))
			var shell = params.get("command", SettingsManager.cfg_shell_command)
			var body = _spawn_pane(type_name, {"shell_command": shell})
			if body == null:
				return _ipc_error("Grid is full")
			return {"pane_id": body.pane_label, "type": type_name}
		"listPanes":
			var panes = []
			for t in _tm.tiles:
				var body = _tm._find_body(t.wrapper)
				if body == null:
					continue
				panes.append({
					"id": body.pane_label,
					"type": body._pane_type(),
					"title": body.get("_last_title") if "_last_title" in body else "",
					"col": t.col, "row": t.row, "cspan": t.cspan, "rspan": t.rspan,
					"focused": body == _tm.last_body,
				})
			return {"panes": panes, "count": panes.size()}
		"killPane":
			var pane_id = str(params.get("pane_id", ""))
			if pane_id == "active" and _tm.last_body:
				_kill(_tm.last_body)
			else:
				var body = _find_pane_by_label(pane_id)
				if body:
					_kill(body)
				else:
					return _ipc_error("Pane '%s' not found" % pane_id)
			return {"success": true}
		"focusPane":
			var pane_id = str(params.get("pane_id", ""))
			var body = _find_pane_by_label(pane_id)
			if body == null:
				return _ipc_error("Pane '%s' not found" % pane_id)
			body.grab_focus()
			return {"success": true}
		"inject":
			var pane_id = str(params.get("pane_id", ""))
			var text = str(params.get("text", ""))
			var body = _find_pane_by_label(pane_id)
			if body == null:
				return _ipc_error("Pane '%s' not found" % pane_id)
			if not body is TerminalPane:
				return _ipc_error("Pane '%s' is not a terminal" % pane_id)
			body._terminal.send_line(text)
			return {"success": true}
		"layoutSave":
			var name = str(params.get("name", ""))
			if name == "":
				return _ipc_error("Profile name required")
			ProfileManager.add_profile(name, _gather_tiles())
			return {"success": true, "name": name}
		"layoutLoad":
			var name = str(params.get("name", ""))
			for p in ProfileManager.profiles:
				if p.get("name", "") == name:
					_do_activate(p)
					return {"success": true}
			return _ipc_error("Profile '%s' not found" % name)
		"layoutList":
			var names = []
			for p in ProfileManager.profiles:
				names.append(p.get("name", ""))
			return {"layouts": names}
		"version":
			return {"version": "0.3.0", "protocol": "2.0"}
		"shutdown":
			get_tree().quit()
			return {"success": true}
		_:
			return _ipc_error("Unknown method: %s" % method, -32601)

func _ipc_error(msg: String, code := -32000):
	return {"error": {"code": code, "message": msg}}

func _find_pane_by_label(label: String) -> Control:
	for t in _tm.tiles:
		var body = _tm._find_body(t.wrapper)
		if body and body.get("pane_label") == label:
			return body
	return null
func _toggle_settings():
	if _settings_panel == null:
		_settings_panel = SettingsPanel.new(self)
		_settings_panel.name = "SettingsPanel"
		_settings_panel.visible = false
		add_child(_settings_panel)
		_settings_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings_panel.visible = not _settings_panel.visible

func _build_sidebar():
	_sidebar_bg = ColorRect.new()
	_sidebar_bg.name = "SidebarBg"
	_sidebar_bg.color = SettingsManager.cfg_sidebar_bg
	_sidebar_bg.anchor_top = 0.0; _sidebar_bg.anchor_bottom = 1.0
	_sidebar_bg.offset_right = 180
	add_child(_sidebar_bg)

	_sidebar = Sidebar.new()
	_sidebar.name = "Sidebar"
	_sidebar_bg.add_child(_sidebar)
	_sidebar.offset_right = 180
	_sidebar.build(_sidebar_bg)

# ═══════════════════════════════════════════════════════════════════════
# Profiles
# ═══════════════════════════════════════════════════════════════════════

func get_terminal_for_ffi() -> Node:
	for t in _tm.tiles:
		var body = _tm._find_body(t.wrapper)
		if body and body._terminal:
			return body._terminal
	return Node.new()

func _save_current_as_profile():
	# Gather current tiles
	var ts = _gather_tiles()

	if ts.is_empty():
		ToastManager.warn("No panes to save")
		return

	# Build save dialog
	var dialog = ConfirmationDialog.new()
	dialog.title = "Save Profile"
	dialog.ok_button_text = "Save"
	dialog.cancel_button_text = "Cancel"

	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	dialog.add_child(v)

	var name_label = Label.new(); name_label.text = "Profile name:"
	v.add_child(name_label)
	var name_inp = LineEdit.new(); name_inp.placeholder_text = "My Profile"
	v.add_child(name_inp)

	var panes_label = Label.new(); panes_label.text = "Pane commands (edit to customize):"
	v.add_child(panes_label)
	var sc = ScrollContainer.new()
	sc.custom_minimum_size = Vector2(300, 200)
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(sc)
	var panes_v = VBoxContainer.new()
	sc.add_child(panes_v)

	var shell_editors: Array[LineEdit] = []
	for i in ts.size():
		var row = HBoxContainer.new()
		var lbl = Label.new(); lbl.text = "Pane %d:" % (i + 1)
		lbl.custom_minimum_size = Vector2(55, 0)
		row.add_child(lbl)
		var le = LineEdit.new(); le.text = ts[i].get("settings", {}).get("shell", SettingsManager.cfg_shell_command)
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		shell_editors.append(le)
		row.add_child(le)
		panes_v.add_child(row)

	# OK only when name is non-empty
	name_inp.text_changed.connect(func(t: String):
		dialog.get_ok_button().disabled = (t.strip_edges() == "")
	)
	dialog.confirmed.connect(func():
		var profile_name = name_inp.text.strip_edges()
		if profile_name == "": return
		for i in ts.size():
			var s = ts[i].get("settings", {})
			s["shell"] = shell_editors[i].text
			if not ts[i].has("settings"): ts[i]["settings"] = s
		ProfileManager.add_profile(profile_name, ts)
		ToastManager.info("Profile '%s' saved" % profile_name)
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)

	add_child(dialog)
	dialog.popup_centered()
	# Disable OK initially (empty name)
	name_inp.text_changed.emit("")

func _activate_profile(p_name: String):
	var idx = -1
	var profs = ProfileManager.profiles
	for i in profs.size():
		if profs[i].get("name", "") == p_name:
			idx = i
			break
	if idx == -1: return
	var profile = profs[idx]

	# Workspace trust: check for shell mismatch in profile tiles
	var profile_tiles = profile.get("tiles", [])
	var untrusted := false
	for td in profile_tiles:
		if not (td is Dictionary): continue
		var settings = td.get("settings", {})
		var sh = settings.get("shell", td.get("shell", ""))
		if sh != "" and sh != SettingsManager.cfg_shell_command:
			untrusted = true
			break

	if untrusted:
		_show_profile_trust_dialog(profile, profile_tiles)
		return

	_do_profile_activate(profile)

func _show_profile_trust_dialog(profile: Dictionary, tiles: Array):
	var dialog = ConfirmationDialog.new()
	dialog.title = "Workspace Trust"
	dialog.dialog_text = "This profile contains panes with a different shell than your current default (%s).\n\nDo you want to activate it anyway?" % SettingsManager.cfg_shell_command
	dialog.ok_button_text = "Activate"
	dialog.cancel_button_text = "Cancel"
	dialog.confirmed.connect(func():
		_do_activate(profile)
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()

func _do_profile_activate(profile: Dictionary):
	var tiles = profile.get("tiles", [])
	# Confirm if workspace has existing panes
	if _tm.tiles.size() > 0:
		var dialog = ConfirmationDialog.new()
		dialog.title = "Activate Profile"
		dialog.dialog_text = "Activating a profile will replace your current layout. Continue?"
		dialog.ok_button_text = "Activate"
		dialog.cancel_button_text = "Cancel"
		dialog.confirmed.connect(func():
			_do_activate(profile)
			dialog.queue_free()
		)
		dialog.canceled.connect(dialog.queue_free)
		add_child(dialog)
		dialog.popup_centered()
	else:
		_do_activate(profile)

func _do_activate(profile: Dictionary):
	_reset()
	var tiles = profile.get("tiles", [])
	for td in tiles:
		if not (td is Dictionary): continue
		var settings = td.get("settings", {})
		var type_name = settings.get("type", "terminal")

		var body = _tm.create_body(type_name)
		if body == null: continue
		body.apply_settings(settings)

		if type_name == "terminal":
			var sh = settings.get("shell", td.get("shell", SettingsManager.cfg_shell_command))
			if sh == null or sh == "": sh = SettingsManager.cfg_shell_command
			SettingsManager.apply_to_terminal(body)
			body.shell_command = sh

		var title = PaneTypes.ALL.get(type_name, {}).get("name", type_name)
		var w = _tm._build_wrapper_body(body, title)

		if type_name == "terminal":
			body.title_changed.connect(func(t: String):
				var lbl = w.get_node_or_null("BodyVBox/TitleBar/TitleLabel")
				if lbl: lbl.text = " " + t
			)

		_grid.add_child(w)
		body.focus_entered.connect(func(): _tm.last_body = body)
		_tm.tiles.append({wrapper = w, col = td.get("col", 0), row = td.get("row", 0),
			cspan = td.get("cspan", GRID), rspan = td.get("rspan", GRID)})
	_apply_layout(); _list()
	ToastManager.info("Profile '%s' activated" % profile.get("name", ""))

func _delete_profile(idx: int):
	ProfileManager.delete_profile(idx)
	ToastManager.info("Profile deleted")

func _refresh_profile_buttons():
	if _sidebar:
		_sidebar.update_profile_list(ProfileManager.get_profiles())
