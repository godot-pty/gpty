extends Control
class_name Workspace
# gpty Workspace — tiling grid of panes with title bars.
# Tile lifecycle is delegated to TerminalManager.

const GRID = 12
const TITLEBAR_HEIGHT = WindowChrome.HEIGHT


var _sidebar: Sidebar
var _sidebar_bg: ColorRect
var _palette: Control
var _grid: Control
var _settings_panel: SettingsPanel
var _tm: TerminalManager = TerminalManager.new()
var _status_bar: StatusBar
var _titlebar: Control = null
var _chrome: WindowChrome = null
var _workspaces: Array[Dictionary] = []  # {name: String, grid: Control, tm: TerminalManager}
var _active: int = 0
var _active_profile: String = ""  # last successfully activated profile (sidebar accent)

func _ready():
	show()
	_chrome = WindowChrome.new()
	_titlebar = _chrome.build(self)

	_grid = Control.new()
	add_child(_grid)

	var overlay = load("res://scenes/ui/toast_overlay.gd").new()
	add_child(overlay)
	# Workspace grids are added later (extra workspaces at restore time);
	# without a z bump these panels render UNDER them and appear broken.
	overlay.z_index = 100

	var pane_settings = load("res://scenes/ui/pane_settings_panel.gd").new()
	add_child(pane_settings)
	pane_settings.z_index = 100
	_tm._pane_settings_panel = pane_settings

	_build_sidebar()

	_status_bar = StatusBar.new()
	_status_bar.name = "StatusBar"
	add_child(_status_bar)

	ProfileManager.load_profiles()
	_wire_sidebar_signals()
	_refresh_profile_buttons()
	_wire_tm(_tm)
	_init_workspaces()

	# Push concepts to Rust engine — must wait for first frame (GDExtension ready)
	_push_concepts_deferred()

	# Per-type keyboard shortcuts
	for key in PaneTypes.ALL:
		var info = PaneTypes.ALL[key]
		var shortcut := str(info.get("shortcut", ""))
		if shortcut.strip_edges() == "":
			continue
		ShortcutManager.register("app:new_" + key, shortcut, func(): var b = _spawn_pane(key); if b: b.grab_focus())
	ShortcutManager.register("app:close_pane", "Ctrl+Shift+W", func(): _kill_last())
	ShortcutManager.register("app:toggle_sidebar", "Ctrl+Shift+B", _toggle_sidebar)
	ShortcutManager.register("app:toggle_palette", "Ctrl+Shift+P", _toggle_palette)
	ShortcutManager.register("app:toggle_fullscreen", "F11", _chrome.toggle_fullscreen)
	ShortcutManager.register("app:toggle_fullscreen_alt", "Ctrl+Shift+M", _chrome.toggle_fullscreen)
	ShortcutManager.register("app:reset_workspace", "Ctrl+Shift+R", func():
		_do_reset()
	)
	ShortcutManager.register("app:next_workspace", "Ctrl+PageDown", func():
		if not _workspaces.is_empty():
			_switch_workspace(clampi(_active + 1, 0, _workspaces.size() - 1))
	)
	ShortcutManager.register("app:prev_workspace", "Ctrl+PageUp", func():
		if not _workspaces.is_empty():
			_switch_workspace(clampi(_active - 1, 0, _workspaces.size() - 1))
	)

	SettingsManager.settings_changed.connect(_on_settings_changed)
	ConceptManager.concepts_changed.connect(_push_concepts_to_engine)
	_on_settings_changed()
	_apply_window_mode.call_deferred()
	if SettingsManager.cfg_window_mode == 0: _chrome.restore_position()

func _on_settings_changed():
	for t in _tm.tiles:
		var body = _tm._find_body(t.wrapper)
		if body and body is TerminalPane:
			SettingsManager.apply_to_terminal(body)
	_apply_ui_colors()
	_sync_pane_titlebars()
	_apply_fps_setting()
	_apply_window_mode()

## UI chrome colors (wrapper bg/border, pane titlebars, sidebar, window
## titlebar) are read at build time; without a live re-apply they'd only
## take effect for panes spawned after the change. Update every wrapper
## in every workspace (hidden workspaces keep their panes alive).
func _apply_ui_colors():
	if _sidebar_bg:
		_sidebar_bg.color = SettingsManager.cfg_sidebar_bg
	if _titlebar:
		var chrome_bg := _titlebar.get_node_or_null("TitleBarBg")
		if chrome_bg is ColorRect:
			chrome_bg.color = SettingsManager.cfg_title_bar_bg
	for ws in _workspaces:
		for t in ws.tm.tiles:
			var wrapper: Control = t.wrapper
			var sb := wrapper.get_theme_stylebox("panel") as StyleBoxFlat
			if sb:
				sb.bg_color = SettingsManager.cfg_wrapper_bg
				sb.border_color = SettingsManager.cfg_wrapper_border
			var tb := wrapper.get_node_or_null("BodyVBox/TitleBar")
			if tb:
				var tbg := tb.get_node_or_null("TitleBarBg")
				if tbg is ColorRect:
					tbg.color = SettingsManager.cfg_title_bar_bg

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
	if what == NOTIFICATION_WM_CLOSE_REQUEST: _chrome.save_position()

# NOTE: We save in _exit_tree(), not NOTIFICATION_WM_CLOSE_REQUEST.
# WM_CLOSE_REQUEST does not fire when the Godot editor stops the game,
# only on actual window close in standalone builds. _exit_tree() fires
# reliably whenever the scene tree is torn down.

func _exit_tree():
	_chrome.save_position()
	_save()
	SettingsManager.save_settings()

func _apply_window_mode():
	_chrome.apply_mode()
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
	var ws := _active_workspace()
	if ws.is_empty():
		return null
	return _spawn_pane_into(ws, type_name, opts)

func _spawn_pane_into(ws: Dictionary, type_name: String, opts := {}) -> Control:
	var tm: TerminalManager = ws.tm
	var body = tm.spawn_pane(type_name, opts)
	if body == null:
		ToastManager.warn("Cannot add pane — grid is full")
		return null
	var w = tm.tiles[-1].wrapper
	_add_body_to_grid_into(ws, w, body, PaneTypes.ALL[type_name]["name"])
	return body

func _add_body_to_grid(w: Control, body: Control, label: String):
	_add_body_to_grid_into(_active_workspace(), w, body, label)

func _add_body_to_grid_into(ws: Dictionary, w: Control, body: Control, label: String):
	if ws.is_empty():
		return
	_attach_pane_into(ws, w, body)
	_sync_pane_titlebars()
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
		_ensure_unique_attachment_id(body)
		_grid.add_child(w)
		body.focus_entered.connect(func(): _tm.last_body = body)
	_apply_layout()
	_list()
	ToastManager.info("Spawned %d terminals" % bodies.size())
	if bodies.size() > 0: bodies[-1].grab_focus()

func _kill(body: Control):
	var ws := _workspace_for_body(body)
	if ws.is_empty():
		return
	# _refresh_status_bar keeps last_body synced to the focus owner, so this
	# tells us whether the pane being closed was the one holding the keyboard.
	var held_focus: bool = ws.tm.last_body == body
	ws.tm.kill(body)
	_close_pane_settings_for(body)
	_apply_layout()
	_list()
	if held_focus:
		# Otherwise the freed node takes focus with it and typing reaches
		# nothing until the user clicks a pane. Only terminals take keyboard
		# focus, so hand it to a surviving terminal.
		for t in ws.tm.tiles:
			var survivor = ws.tm._find_body(t.wrapper)
			if survivor is TerminalPane:
				ws.tm.last_body = survivor
				survivor.grab_focus()
				break
	ToastManager.info("Pane closed")

## Close the pane settings popup when its target pane is torn down. The
## panel also self-closes via _process when its target is freed by other
## paths (swap, reset, restore, workspace close) — this is the immediate,
## explicit close on the primary kill path.
func _close_pane_settings_for(body: Control):
	var panel: Control = _tm._pane_settings_panel
	if panel and panel.visible and panel._target == body:
		panel.close()

func _swap_pane(body: Control, new_type_name: String):
	var ws := _workspace_for_body(body)
	if ws.is_empty():
		return
	var tm: TerminalManager = ws.tm
	var old_wrapper = null
	for t in tm.tiles:
		if tm._find_body(t.wrapper) == body:
			old_wrapper = t.wrapper
			break

	var new_body = tm.swap_pane(body, new_type_name)
	if new_body == null: return
	# The old body is freed by the swap; close its settings popup like a kill.
	_close_pane_settings_for(body)

	# Find the new wrapper (tile's wrapper was replaced in-place)
	var new_wrapper = null
	for t in tm.tiles:
		if tm._find_body(t.wrapper) == new_body:
			new_wrapper = t.wrapper
			break

	# Remove old wrapper from grid, add new one.
	if old_wrapper:
		ws.grid.remove_child(old_wrapper)
	if new_wrapper:
		_attach_pane_into(ws, new_wrapper, new_body)

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

## User-facing reset: clears the active workspace's panes AND the
## profile-accent state (a reset layout is no longer "that profile").
func _do_reset():
	_reset()
	_active_profile = ""
	_refresh_profile_buttons()

# ═══════════════════════════════════════════════════════════════════════
# Workspaces — independent pane sets, keep-alive
# ═══════════════════════════════════════════════════════════════════════

func _update_workspace_ui():
	if _sidebar:
		_sidebar.update_workspace_list(_workspace_names(), _active)

## Every pane is addressed over IPC by its `attachment_id`, and resolution
## returns the first match — so two panes sharing an id make inject, read,
## status, wait, kill and focus silently act on the wrong one. Duplicates
## come from saved tiles (a profile or workspace file naming the same id
## twice) or ids typed into the pane settings; regenerate on collision.
func _ensure_unique_attachment_id(body: Control):
	var id: String = str(body.get("attachment_id"))
	if id == "":
		return
	if not _attachment_id_in_use(id, body):
		return
	var replacement := PaneTypes.generate_attachment_id()
	for _i in 32:
		if not _attachment_id_in_use(replacement, body):
			break
		replacement = PaneTypes.generate_attachment_id()
	body.attachment_id = replacement
	ToastManager.warn("Duplicate pane id '%s' renamed to '%s'" % [id, replacement])

## True when any *other* pane in any workspace already carries `id`.
func _attachment_id_in_use(id: String, except: Control) -> bool:
	for ws in _workspaces:
		if ws.is_empty() or not ws.has("tm"):
			continue
		for t in ws.tm.tiles:
			var other = ws.tm._find_body(t.wrapper)
			if other == null or other == except:
				continue
			if str(other.get("attachment_id")) == id:
				return true
	return false

## Single choke point where a pane enters a workspace: adds the wrapper to
## the grid, wires activation tracking, and (for terminals) the dynamic
## title. Spawn, restore, and swap all funnel through here so a new pane
## type is wired correctly everywhere.
func _attach_pane_into(ws: Dictionary, w: Control, body: Control):
	_ensure_unique_attachment_id(body)
	ws.grid.add_child(w)
	_wire_pane_activation(ws, w, body)
	if body is TerminalPane:
		body.title_changed.connect(func(t: String):
			var lbl = w.get_node_or_null("BodyVBox/TitleBar/TitleLabel")
			if lbl: lbl.text = " " + t
		)

func _wire_pane_activation(ws: Dictionary, _w: Control, body: Control):
	# Pane activation on plain clicks is handled in _input via wrapper
	# hit-testing — container ancestors skip gui_input propagation, so
	# wiring the wrapper does not work. This covers the focusable case.
	body.focus_entered.connect(func(): ws.tm.last_body = body)

## Focus owner → owning pane. Called every frame from _refresh_status_bar,
## but the answer only changes when the focus owner does: walking every tile
## for every ancestor was O(depth x tiles) node lookups per frame.
var _focus_owner_cache: Control = null
var _focus_body_cache: Control = null

func _body_of_focus_owner(owner: Control) -> Control:
	if owner == _focus_owner_cache and is_instance_valid(_focus_body_cache):
		return _focus_body_cache
	# A focusable child (e.g. the Inspector's input field) owns keyboard
	# focus without firing the pane's focus_entered — walk up to the pane.
	var found: Control = null
	var node = owner
	while node != null and found == null:
		for t in _tm.tiles:
			var b = _tm._find_body(t.wrapper)
			if b == node:
				found = b
				break
		node = node.get_parent()
	_focus_owner_cache = owner
	_focus_body_cache = found
	return found

func _wire_tm(tm: TerminalManager):
	tm.on_close = func(body: Control): _kill(body)
	tm.on_swap = _swap_pane
	tm.on_open_pane_settings = func(body: Control):
		# The pane settings popup and the global settings panel are sibling
		# overlays; opening one closes the other so they never stack.
		if _settings_panel and _settings_panel.visible:
			_settings_panel.visible = false
		if tm._pane_settings_panel:
			tm._pane_settings_panel.open_for(body)

func _active_workspace() -> Dictionary:
	if _workspaces.is_empty() or _active < 0 or _active >= _workspaces.size():
		return {}
	return _workspaces[_active]

func _workspace_for_body(body: Control) -> Dictionary:
	for ws in _workspaces:
		for t in ws.tm.tiles:
			if ws.tm._find_body(t.wrapper) == body:
				return ws
	return {}

func _new_workspace_container(ws_name: String) -> Dictionary:
	var grid = Control.new()
	grid.name = "Grid%d" % _workspaces.size()
	grid.anchor_left = 0.0; grid.anchor_right = 1.0
	grid.anchor_top = 0.0; grid.anchor_bottom = 1.0
	add_child(grid)
	var tm = TerminalManager.new()
	tm._pane_settings_panel = _tm._pane_settings_panel
	_wire_tm(tm)
	grid.visible = false
	grid.process_mode = Node.PROCESS_MODE_DISABLED
	return {"name": ws_name, "grid": grid, "tm": tm}

func _workspace_names() -> Array[String]:
	var out: Array[String] = []
	for ws in _workspaces:
		out.append(str(ws.name))
	return out

func _next_workspace_number() -> int:
	var max_n := 0
	for ws in _workspaces:
		var ws_name: String = str(ws.name)
		if ws_name.begins_with("Workspace "):
			max_n = maxi(max_n, ws_name.substr("Workspace ".length()).to_int())
	return max_n + 1

func _apply_active_workspace_view():
	if _workspaces.is_empty():
		return
	_tm = _workspaces[_active].tm
	_grid = _workspaces[_active].grid
	for i in _workspaces.size():
		_workspaces[i].grid.visible = (i == _active)
		_workspaces[i].grid.process_mode = Node.PROCESS_MODE_INHERIT if i == _active else Node.PROCESS_MODE_DISABLED
	_update_workspace_ui()
	_apply_layout()
	_list()
	_sync_pane_titlebars()
	_refresh_status_bar()
	if _tm.last_body and is_instance_valid(_tm.last_body):
		_tm.last_body.grab_focus()

func _switch_workspace(idx: int):
	if _workspaces.is_empty() or idx < 0 or idx >= _workspaces.size() or idx == _active:
		return
	_save_workspaces_to_store()
	_active = idx
	_apply_active_workspace_view()
	# Hidden panes missed settings broadcasts; re-apply to the incoming set.
	_on_settings_changed()

func _add_workspace():
	if _workspaces.is_empty():
		return
	if _workspaces.size() >= 8:
		ToastManager.warn("Maximum 8 workspaces")
		return
	var ws_name = "Workspace %d" % _next_workspace_number()
	var ws = _new_workspace_container(ws_name)
	_workspaces.append(ws)
	# Blank slate: no auto-spawned terminal — the user decides what fills it.
	_switch_workspace(_workspaces.size() - 1)

func _close_workspace(idx: int):
	if _workspaces.is_empty() or idx < 0 or idx >= _workspaces.size():
		return
	if _workspaces.size() <= 1:
		ToastManager.info("Cannot close the last workspace")
		return
	var ws = _workspaces[idx]
	_workspaces.remove_at(idx)
	ws.tm.reset()
	ws.grid.queue_free()
	if idx == _active:
		_active = clampi(idx, 0, _workspaces.size() - 1)
		_apply_active_workspace_view()
		_on_settings_changed()
	elif idx < _active:
		_active -= 1
	_update_workspace_ui()
	_save_workspaces_to_store()

func _rename_workspace(idx: int, new_name: String):
	if _workspaces.is_empty() or idx < 0 or idx >= _workspaces.size():
		return
	var clean := WorkspaceStore.sanitize_name(new_name)
	if _workspaces[idx].name == clean:
		return  # no-op — also absorbs the duplicate blur/enter commit
	_workspaces[idx].name = clean
	_update_workspace_ui()
	_save_workspaces_to_store()

# ═══════════════════════════════════════════════════════════════════════
# Persistence
# ═══════════════════════════════════════════════════════════════════════

func _gather_tiles() -> Array[Dictionary]:
	return _gather_tiles_from(_tm)

func _gather_tiles_from(tm: TerminalManager) -> Array[Dictionary]:
	var ts: Array[Dictionary] = []
	for t in tm.tiles:
		var body = tm._find_body(t.wrapper)
		var settings = body._get_layout_state() if body and body.has_method("_get_layout_state") else {}
		ts.append({
			"col": t.col, "row": t.row,
			"cspan": t.cspan, "rspan": t.rspan,
			"settings": settings,
		})
	return ts

func _save():
	_save_workspaces_to_store()

func _save_workspaces_to_store():
	if _workspaces.is_empty():
		return
	WorkspaceStore.save(_active, _all_layouts())

func _all_layouts() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for ws in _workspaces:
		out.append({"name": ws.name, "layout": _gather_tiles_from(ws.tm)})
	return out

# ── Workspace (tab set) lifecycle ─────────────────────────────────────

func _init_workspaces():
	_teardown_workspaces()
	var store = WorkspaceStore.load()
	var wss: Array = store.get("workspaces", [])
	if wss.is_empty():
		var legacy = WorkspaceStore.import_legacy_layout()
		if not legacy.is_empty():
			wss = [{"name": "Workspace 1", "layout": legacy}]
	var entries: Array[Dictionary] = []
	for entry in wss:
		if not (entry is Dictionary):
			continue
		entries.append({
			"name": WorkspaceStore.sanitize_name(str(entry.get("name", ""))),
			"layout": _tiles_from(entry.get("layout", [])),
		})
	if entries.is_empty():
		entries = [{"name": "Workspace 1", "layout": []}]
	var active: int = clampi(int(store.get("active", 0)), 0, entries.size() - 1)

	# Workspace trust: warn if any saved shell differs from the configured
	# default. Cancel keeps the layout but swaps untrusted shells out —
	# every workspace is rebuilt with the default shell instead.
	var untrusted: Array = []
	for i in entries.size():
		if _tiles_untrusted(_tiles_from(entries[i].get("layout", []))):
			untrusted.append(i)
	if not untrusted.is_empty():
		_show_multi_trust_dialog(entries, active, untrusted)
		return
	_build_workspaces(entries, active)

func _teardown_workspaces():
	for i in _workspaces.size():
		var ws = _workspaces[i]
		ws.tm.reset()
		if i > 0:
			ws.grid.queue_free()
	_workspaces.clear()

func _build_workspaces(entries: Array[Dictionary], active: int):
	for i in entries.size():
		var ws: Dictionary
		if i == 0:
			ws = {"name": entries[i].get("name", "Workspace 1"), "grid": _grid, "tm": _tm}
		else:
			ws = _new_workspace_container(str(entries[i].get("name", "")))
		_workspaces.append(ws)
		_restore_into(ws, _tiles_from(entries[i].get("layout", [])))
	_active = clampi(active, 0, _workspaces.size() - 1)
	_apply_active_workspace_view()

func _restore_into(ws: Dictionary, tiles: Array[Dictionary]):
	var tm: TerminalManager = ws.tm
	var grid: Control = ws.grid
	tm.reset()
	for td in tiles:
		if not (td is Dictionary): continue
		var st = PaneTypes.sanitize_tile(td, GRID)
		if st.is_empty(): continue
		var settings: Dictionary = st["settings"]
		var type_name: String = st["type_name"]

		var body = tm.create_body(type_name)
		if body == null: continue
		body.apply_settings(settings)

		# For terminals: apply global defaults, then the per-tile command.
		# "command" carries a tool override (e.g. "herdr", "lazygit", "nvim");
		# "shell" is the legacy shell-binary key.  Priority: command > shell > default.
		# Both run through sanitize_shell — profile data is untrusted.
		if type_name == "terminal":
			var raw = settings.get("command", settings.get("shell", td.get("shell", "")))
			var sh: String = PaneTypes.sanitize_shell(raw, SettingsManager.cfg_shell_command)
			SettingsManager.apply_to_terminal(body)
			body.shell_command = sh

		var title = PaneTypes.ALL.get(type_name, {}).get("name", type_name)
		var w = tm._build_wrapper_body(body, title)

		_attach_pane_into(ws, w, body)
		tm.tiles.append({wrapper = w, col = st["col"], row = st["row"],
			cspan = st["cspan"], rspan = st["rspan"]})
	if tm.tiles.is_empty():
		_spawn_pane_into(ws, "terminal")

func _tiles_from(raw: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for td in raw:
		if td is Dictionary:
			out.append(td)
	return out

func _tiles_untrusted(tiles: Array[Dictionary]) -> bool:
	for td in tiles:
		var settings = td.get("settings", {})
		if not (settings is Dictionary): continue
		var sh = settings.get("shell", td.get("shell", ""))
		if sh is String and sh != "" and sh != SettingsManager.cfg_shell_command:
			return true
	return false

func _show_multi_trust_dialog(entries: Array[Dictionary], active: int, untrusted: Array):
	var dialog = ConfirmationDialog.new()
	dialog.title = "Workspace Trust"
	dialog.dialog_text = "This layout contains %d workspace(s) with a different shell than your current default (%s).\n\nRestore them anyway?" % [untrusted.size(), SettingsManager.cfg_shell_command]
	dialog.ok_button_text = "Restore"
	dialog.cancel_button_text = "Cancel"
	dialog.confirmed.connect(func():
		_build_workspaces(entries, active)
		dialog.queue_free()
	)
	dialog.canceled.connect(func():
		for i in untrusted:
			var empty: Array[Dictionary] = []
			entries[i]["layout"] = empty
		_build_workspaces(entries, active)
		dialog.queue_free()
	)
	add_child(dialog)
	dialog.popup_centered()

func _restore():
	# Palette "load": reload the saved workspace set from disk.
	_init_workspaces()

# ═══════════════════════════════════════════════════════════════════════
# Palette
# ═══════════════════════════════════════════════════════════════════════

func _unhandled_input(event):
	if _palette and _palette.visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_palette.visible = false
		get_viewport().set_input_as_handled()

func _input(event):
	# Raw input — fires before GUI consumption, which is required: pane
	# bodies contain RichTextLabels/ScrollContainers that consume clicks,
	# and _unhandled_input would never see them. The workspace fills the
	# window, so the event's viewport position maps 1:1 to canvas space.
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_activate_pane_under_mouse(event.position)

## Uniform click-to-activate: any left click inside a pane (body, titlebar
## background, or an inner widget) makes that pane the active one. The
## sidebar/status bar are not tile wrappers, so their clicks are no-ops.
## Non-terminal panes release the old keyboard owner so keystrokes stop
## flowing to a terminal the user just left (read-only panes swallow keys
## by design).
func _activate_pane_under_mouse(mouse: Vector2):
	var ws := _active_workspace()
	if ws.is_empty():
		return
	# A visible pane settings popup owns its clicks: activating (or
	# releasing focus from) panes underneath the overlay while the user
	# interacts with it corrupts the interaction.
	var panel: Control = ws.tm._pane_settings_panel
	if panel and panel.visible:
		return
	for t in ws.tm.tiles:
		var w: Control = t.wrapper
		if not w.get_global_rect().has_point(mouse):
			continue
		var body = ws.tm._find_body(w)
		if body == null:
			continue
		ws.tm.last_body = body
		if not (body is TerminalPane):
			var owner := get_viewport().gui_get_focus_owner()
			if owner:
				owner.release_focus()
		return

func _toggle_palette():
	if _palette == null:
		_palette = _build_palette()
		_palette.visible = false  # start hidden — the first toggle must OPEN it
		_palette.z_index = 100
		add_child(_palette)
		_palette.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_palette.visible = not _palette.visible
	if _palette.visible:
		# Input picking uses reverse tree order (z_index is rendering-only);
		# keep the palette topmost over workspaces added after first use.
		move_child(_palette, -1)
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

	var cmds = PaneTypes.build_palette_commands()
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
	_sidebar.request_reset.connect(func(): _do_reset())
	_sidebar.request_focus.connect(func(body: Control):
		# Same uniform semantics as clicking the pane itself: the row click
		# activates the pane; only terminals take keyboard focus.
		var bws := _workspace_for_body(body)
		if not bws.is_empty():
			bws.tm.last_body = body
		if body is TerminalPane:
			body.grab_focus()
		else:
			var owner := get_viewport().gui_get_focus_owner()
			if owner:
				owner.release_focus()
	)
	_sidebar.request_minimize.connect(func(body: Control): _on_pane_minimize(body))
	_sidebar.request_position_swap.connect(func(body: Control, btn: Button): _on_pane_position_swap(body, btn))
	_sidebar.request_type_swap.connect(func(body: Control, btn: Button): _on_pane_type_swap(body, btn))
	_sidebar.request_pane_settings.connect(func(body: Control): _tm._open_pane_settings(body))
	_sidebar.toggled.connect(func(): _on_sidebar_toggled())
	_sidebar.request_profile.connect(_activate_profile)
	_sidebar.request_profile_rename.connect(_rename_profile)
	_sidebar.request_window_mode.connect(_chrome.on_window_mode_selected)
	_sidebar.request_search.connect(_open_active_search)
	_sidebar.request_workspace_switch.connect(_switch_workspace)
	_sidebar.request_workspace_add.connect(_add_workspace)
	_sidebar.request_workspace_close.connect(_close_workspace)
	_sidebar.request_workspace_rename.connect(_rename_workspace)
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
	var active_body: Control = _tm.last_body if (_tm.last_body and is_instance_valid(_tm.last_body)) else null
	_sidebar.update_pane_list(panes, active_body)

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

var _pending_waits: Dictionary = {}

func _process(_delta: float):
	# Concept event polling — must run even before sidebar is ready
	_poll_agent_events()
	_poll_concept_events()
	_poll_ipc_requests()
	_poll_pending_waits()
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

## Last pane identity pushed to the status bar, so the per-frame refresh can
## skip a string reformat and label re-layout when nothing changed.
var _status_pane_label := ""
var _status_pane_type := ""

func _refresh_status_bar():
	if _status_bar == null: return
	var body = _tm.last_body
	# A focusable child (Inspector input) owns keyboard focus without the
	# pane's focus_entered ever firing — resolve the owning pane.
	var owner := get_viewport().gui_get_focus_owner()
	var owner_body := _body_of_focus_owner(owner)
	if owner_body:
		_tm.last_body = owner_body
		body = owner_body
	var label: String = body.pane_label if body else ""
	var type_name: String = body._pane_type() if body else ""
	if label == _status_pane_label and type_name == _status_pane_type:
		return
	_status_pane_label = label
	_status_pane_type = type_name
	if body:
		_status_bar.set_pane_info(label, type_name)
	else:
		_status_bar.set_pane_info("", "")
	_status_bar.set_window_mode(SettingsManager.cfg_window_mode)
	# Sidebar pane accent follows focus (deduped inside the sidebar).
	if _sidebar:
		_sidebar.set_active_pane(body if (body and is_instance_valid(body)) else null)

func _poll_agent_events():
	var raw := str(GptyTerminal.drain_agent_events())
	if raw == "" or raw == "[]":
		return
	var events = JSON.parse_string(raw)
	if not (events is Array):
		return
	# One pass per drain: session-id → source map plus receiver list, so each
	# event no longer re-scans every tile twice (O(E×T²) → O(T + E×R)).
	# Hidden workspaces keep receiving events (their PTYs stay alive).
	var source_by_session := {}
	var receivers: Array[Control] = []
	for ws in _workspaces:
		for tile in ws.tm.tiles:
			var body = ws.tm._find_body(tile.wrapper)
			if body == null:
				continue
			if body.has_method("receive_agent_event"):
				receivers.append(body)
			if body is TerminalPane and body.get("_terminal") != null:
				var session_id := str(body._terminal.get_terminal_session_id())
				if session_id != "":
					source_by_session[session_id] = body
	for envelope in events:
		if not (envelope is Dictionary):
			continue
		var source: Control = source_by_session.get(str(envelope.get("terminal_session_id", "")), null)
		if source == null:
			continue
		var event = envelope.get("event", {})
		# Tier 1 (authoritative): capability-authenticated events set the
		# terminal's agent state before routing. Display state only.
		var state: String = Workspace.agent_state_for_event(event)
		if state != "" and source.get("_terminal") != null:
			source._terminal.set_agent_state(state)
		var source_id: String = source.attachment_id if source.attachment_id != "" else source.pane_label
		for receiver in receivers:
			receiver.receive_agent_event(envelope, source_id)

## Map a generic-vocabulary event to the Tier 1 agent state it declares.
## Empty string = the event carries no state declaration.
static func agent_state_for_event(event: Dictionary) -> String:
	if not (event is Dictionary):
		return ""
	match str(event.get("name", "")):
		"agent.started":
			return "working"
		"agent.settled":
			return "completed"
		"session.bound", "session.shutdown":
			return "idle"
		"tool.finished":
			if bool(event.get("is_error", false)):
				return "needs-attention"
	return ""

# ═══════════════════════════════════════════════════════════════════════
# Concept event routing
# ═══════════════════════════════════════════════════════════════════════

func _poll_concept_events():
	# Hidden workspaces keep routing captures: UntilStop timeouts run in
	# Rust regardless of process_mode, and routing stays within each
	# workspace's pane set.
	for ws in _workspaces:
		_poll_concept_events_for(ws)

func _poll_concept_events_for(ws: Dictionary):
	var all_bodies: Array[Control] = []
	var terms: Array[Control] = []
	for t in ws.tm.tiles:
		var body = ws.tm._find_body(t.wrapper)
		if body == null:
			continue
		all_bodies.append(body)
		if body is TerminalPane:
			terms.append(body)
	for body in terms:
		var term = body.get("_terminal")
		if term == null:
			continue
		var events = term.drain_concept_events()
		for ev in events:
			if not (ev is Dictionary):
				continue
			var ok = ConceptRouter.route_capture_event(all_bodies, ev, term)
			if not ok:
				var target := str(ev.get("target_pane_type", ""))
				var pane_label := str(PaneTypes.ALL.get(target, {}).get("name", target))
				var source := str(body.pane_label) if body.get("pane_label") != null else "?"
				ToastManager.warn("No %s pane open for '%s' output (from %s)" % [
					pane_label, ev.get("concept_name", ""), source])
			GptyTerminal.emit_event(JSON.stringify({
				"type": "concept",
				"name": str(ev.get("concept_name", "")),
				"source": str(body.attachment_id),
				"target": str(ev.get("target_pane_type", "")),
			}))
# ═══════════════════════════════════════════════════════════════════════
# IPC bridge — polls Rust IPC requests from _process
# ═══════════════════════════════════════════════════════════════════════

func _poll_ipc_requests():
	# GptyTerminal is a GodotClass — call static methods on the class
	var reqs = GptyTerminal.drain_ipc_requests()
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
		if method == "paneWait":
			var w_body = _find_pane_by_label(str(params.get("pane_id", "")))
			if w_body == null or not (w_body is TerminalPane):
				GptyTerminal.respond_ipc(id, false, JSON.stringify(_ipc_error("Pane '%s' not found" % params.get("pane_id", ""))))
				continue
			var w_pattern = str(params.get("pattern", ""))
			if w_pattern == "" or w_pattern.length() > 1024:
				GptyTerminal.respond_ipc(id, false, JSON.stringify(_ipc_error("Invalid wait pattern")))
				continue
			var w_timeout = clampi(int(params.get("timeout_ms", 10000)), 100, 60000)
			_pending_waits[str(id)] = {
				"attachment_id": w_body.attachment_id,
				"pattern": w_pattern,
				"deadline_ms": Time.get_ticks_msec() + w_timeout,
			}
			continue
		var result = _handle_ipc_method(method, params)
		var success = not (result is Dictionary and result.has("error"))
		var result_json = JSON.stringify(result) if typeof(result) != TYPE_STRING else result
		GptyTerminal.respond_ipc(id, success, result_json)

# Poll registered paneWait requests each frame: respond on first regex match
# or deadline. Matching happens in Rust (standard regex crate) per pane.
func _poll_pending_waits():
	if _pending_waits.is_empty():
		return
	var now = Time.get_ticks_msec()
	var done: Array = []
	for wid in _pending_waits:
		var w = _pending_waits[wid]
		var wbody = _find_pane_by_label(str(w.get("attachment_id", "")))
		if wbody == null or not (wbody is TerminalPane):
			GptyTerminal.respond_ipc(int(wid), false, JSON.stringify(_ipc_error("Pane gone")))
			done.append(wid)
			continue
		var line = str(wbody._terminal.check_lines(w["pattern"]))
		if line != "":
			GptyTerminal.respond_ipc(int(wid), true, JSON.stringify({"matched": true, "line": line}))
			done.append(wid)
		elif now >= w["deadline_ms"]:
			GptyTerminal.respond_ipc(int(wid), true, JSON.stringify({"matched": false, "timed_out": true}))
			done.append(wid)
	for wid in done:
		_pending_waits.erase(wid)

func _handle_ipc_method(method: String, params):
	return WorkspaceIpcHandlers.handle(self, method, params)

func _ipc_error(msg: String, code := -32000):
	return WorkspaceIpcHandlers.error(msg, code)

func _find_pane_by_label(label: String) -> Control:
	# Labels (T1) can collide across workspaces; attachment_ids are
	# globally unique. Resolve active-workspace-first for label targeting.
	var ws := _active_workspace()
	if not ws.is_empty():
		var body = _find_in_tm(ws.tm, label)
		if body:
			return body
	for i in _workspaces.size():
		if i == _active:
			continue
		var other = _find_in_tm(_workspaces[i].tm, label)
		if other:
			return other
	return null

func _find_in_tm(tm: TerminalManager, label: String) -> Control:
	for t in tm.tiles:
		var body = tm._find_body(t.wrapper)
		if body and (body.attachment_id == label or body.get("pane_label") == label):
			return body
	return null
func _toggle_settings():
	if _settings_panel == null:
		_settings_panel = SettingsPanel.new(self)
		_settings_panel.name = "SettingsPanel"
		_settings_panel.visible = false
		_settings_panel.z_index = 100
		add_child(_settings_panel)
		_settings_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not _settings_panel.visible:
		# Opening global settings closes the pane settings overlay so the
		# two overlays never stack.
		var panel: Control = _tm._pane_settings_panel
		if panel and panel.visible:
			panel.close()
		# Input picking uses reverse tree order (z_index is rendering-only);
		# stay topmost even when workspaces were added after first open.
		move_child(_settings_panel, -1)
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


func _push_concepts_to_engine():
	for t in _tm.tiles:
		var body = _tm._find_body(t.wrapper)
		if body == null:
			continue
		if body is TerminalPane:
			var term = body.get("_terminal")
			if term == null:
				continue
			var concepts = ConceptManager._merge_concepts()
			var enabled: Array = []
			for c in concepts:
				if c is Dictionary and c.get("enabled", true) == true:
					enabled.append(c)
			# Push the empty set too — see ConceptManager._push_to_rust.
			term.set_global_concepts(JSON.stringify(enabled))
			return
func _push_concepts_deferred():
	# Wait for the scene tree to fully settle (GDExtension + terminal nodes ready)
	await get_tree().create_timer(2.0).timeout
	# The workspace may have been torn down (tests, quick quit) while waiting;
	# resuming on a freed instance would raise a script error.
	if not is_instance_valid(self) or not is_inside_tree():
		return
	_push_concepts_to_engine()
func get_terminal_for_ffi() -> GptyTerminal:
	for t in _tm.tiles:
		var body = _tm._find_body(t.wrapper)
		if body and body._terminal:
			return body._terminal
	return null

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
	var profile := ProfileManager.find_profile(p_name)
	if profile.is_empty():
		return

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

func _show_profile_trust_dialog(profile: Dictionary, _tiles: Array):
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
	var ws := _active_workspace()
	if ws.is_empty():
		return
	_reset()
	var tiles: Array[Dictionary] = []
	for td in profile.get("tiles", []):
		if td is Dictionary:
			tiles.append(td)
	_restore_into(ws, tiles)
	_active_profile = str(profile.get("name", ""))
	_refresh_profile_buttons()
	# Same refresh path as workspace switching: layout, pane list, titlebars,
	# and focus. Skipping it leaves restored wrappers unlaid-out and the
	# sidebar pane list stale until the user switches workspaces.
	_apply_active_workspace_view()
	ToastManager.info("Profile '%s' activated" % profile.get("name", ""))

func _delete_profile(idx: int):
	var profiles := ProfileManager.get_all_profiles()
	var deleted_name := ""
	if idx >= 0 and idx < profiles.size():
		deleted_name = str(profiles[idx].get("name", ""))
	ProfileManager.delete_profile(idx)
	if deleted_name != "" and deleted_name == _active_profile:
		_active_profile = ""
	_refresh_profile_buttons()
	ToastManager.info("Profile deleted")

func _rename_profile(idx: int, new_name: String):
	var profiles := ProfileManager.get_all_profiles()
	var old_name := ""
	if idx >= 0 and idx < profiles.size():
		old_name = str(profiles[idx].get("name", ""))
	var renamed := ProfileManager.rename_profile(idx, new_name)
	if renamed == "":
		ToastManager.warn("Cannot rename profile")
	else:
		if old_name != "" and old_name == _active_profile:
			_active_profile = renamed
		ToastManager.info("Profile renamed to '%s'" % renamed)
	_refresh_profile_buttons()

func _open_active_search():
	var ws := _active_workspace()
	if ws.is_empty():
		return
	var body: Control = ws.tm.last_body if (ws.tm.last_body and is_instance_valid(ws.tm.last_body)) else null
	if not (body is TerminalPane):
		# Fall back to the first terminal in the active workspace.
		for t in ws.tm.tiles:
			var b = ws.tm._find_body(t.wrapper)
			if b is TerminalPane:
				body = b
				break
	if body is TerminalPane:
		body._toggle_search()

func _refresh_profile_buttons():
	if _sidebar:
		_sidebar.update_profile_list(ProfileManager.get_all_profiles(), _active_profile)
