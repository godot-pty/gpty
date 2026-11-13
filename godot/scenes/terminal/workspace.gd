extends Control
class_name Workspace
# gpty Workspace — tiling grid of panes with title bars.
# Tile lifecycle is delegated to TerminalManager.

const TITLEBAR_HEIGHT = WindowChrome.HEIGHT

## Panes named in the running-work confirmation before the rest are counted;
## a bulk close of sixteen panes must still be readable in one dialog.
const RUNNING_ASK_MAX_NAMES = 8

## The running-work confirmation's first line: the caller's action phrase, then
## how much of the set it would stop. Both counts are panes, not processes: a
## pane's foreground job can be a whole process group.
static func running_ask_intro(action: String, busy: int, total: int) -> String:
	if total <= 1:
		return "%s will stop a running process:" % action
	if busy == total:
		return "%s will stop running processes in all %d panes:" % [action, total]
	if busy == 1:
		return "%s will stop a running process in 1 of %d panes:" % [action, total]
	return "%s will stop running processes in %d of %d panes:" % [action, busy, total]

## One pane line of that dialog: its label, the name a user reads for it, and
## its workspace unless the intro already named the workspace.
static func running_ask_entry(
		label: String, display: String, workspace_name: String, qualify: bool) -> String:
	var entry := A11y.one_line(label)
	var shown := A11y.one_line(display)
	if shown != "":
		entry += " (%s)" % shown
	if qualify:
		var ws_shown := A11y.one_line(workspace_name)
		if ws_shown != "":
			entry = "'%s': %s" % [ws_shown, entry]
	return entry

## The workspace cap: the sidebar's new-workspace button, the profile's
## "open in a new workspace" action and the store's clamped `active` index all
## use it, so a ninth tab can never be created by one path and refused by
## another.
const MAX_WORKSPACES := 8

## The workspace a first pane creates when there is none: the app has no seeded
## workspace, so the implicit one is the default the user starts in.
const IMPLIED_WORKSPACE_NAME := "Default"

## The live-pane ceiling for the whole window — every workspace, because a
## hidden workspace's panes keep their PTY, child process and grid alive. Every
## path that can create a pane shares `_pane_ceiling_refusal`: the control
## socket (`newPane`, `paneRun`), the palette and sidebar spawns, a profile
## activation, and a workspace/profile restore from a file.
## Measured on the headless GUI (2026-10-30): a pane costs about 6 MB in its
## shell, and the GUI grows by under 1 MB per pane (279 MB with 64 panes, 323 MB
## with 128); creating panes spends about 40 ms each, so the most one operation
## can legitimately create here is 96 panes — about 0.9 GB (GUI 295 MB, shells
## 596 MB) and 3.9 s, which still fits inside a control-socket caller's 5 s
## timeout; a 128-tile restore overran that timeout and a 300-tile one left
## `list-panes` answering in seconds. One workspace holds 64 panes at the
## divider's `MIN_TILE` floor, so this is one and a half full grids — no
## hand-built layout comes near it — while a caller or a file can no longer
## spend a machine's processes and memory without end.
const MAX_LIVE_PANES := 96

## The three reasons a saved command has nowhere to go. One wording each: the
## palette shows the refused rows' tooltip from these same strings, so a hint
## and the toast that follows it cannot disagree.
const SAVED_NO_PANE := "Saved commands go to a terminal pane, and no pane is active"
const SAVED_NOT_TERMINAL := "Saved commands go to the active terminal pane, and the active pane is not a terminal"
const SAVED_MINIMIZED := "Saved commands go to the active terminal pane, and it is minimized"


var _sidebar: Sidebar
var _sidebar_bg: ColorRect
var _palette: CommandPalette
var _grid: Control
## The scrollable "no panes" guide; one node over the active grid, synced by
## `_apply_layout()` because every create and kill path reaches it. The guide
## itself is `_shortcut_guide`, built once and re-read on every show.
var _empty_state: ScrollContainer = null
## The guide's centre: its minimum height is set to the empty viewport so a
## guide shorter than the window is centred, while a taller one scrolls.
var _empty_center: CenterContainer = null
var _shortcut_guide: ShortcutGuide = null
var _settings_panel: SettingsPanel
var _concept_graph: ConceptGraphEditor = null
var _tm: TerminalManager = TerminalManager.new()
## The permanent empty host. `_tm`/`_grid` point at the active workspace, and
## at this pair when there is none; it is never freed.
var _home_grid: Control
var _home_tm: TerminalManager
var _status_bar: StatusBar
var _titlebar: Control = null
var _chrome: WindowChrome = null
var _workspaces: Array[Dictionary] = []  # {name: String, grid: Control, tm: TerminalManager, profile: String}
var _active: int = 0
var _active_profile: String = ""  # active workspace's profile name (sidebar accent; re-derived on every switch)
var _history_pruned: bool = false  # orphaned-scrollback sweep already attempted
## The quit itself, behind a seam: tests replace it to observe a close request
## without ending the run (`_history_stats_provider`'s pattern).
var quit_action: Callable = func(): get_tree().quit()
var _quit_asking: bool = false  # a pane-ask walk for quitting is in flight
## The one place a JSON-RPC answer leaves the GUI, behind a seam for the same
## reason as `quit_action`: `GptyTerminal.respond_ipc` has no push point from
## GUT, so the drain's deferred-answer tests replace this to observe what a
## held answer said (and to keep answering a socket nobody listens on).
var send_ipc_answer: Callable = func(id: int, ok: bool, payload: String) -> void:
	GptyTerminal.respond_ipc(id, ok, payload)

func _ready():
	show()
	# One Theme for the whole window: the workspace is the scene root, so every
	# pane, overlay, popup and dialog below it inherits this instance.
	theme = UiTheme.build()
	# Where nothing is drawn the viewport's clear colour shows: an empty
	# workspace used to be Godot's default grey.
	RenderingServer.set_default_clear_color(UiPalette.active().BG)
	_chrome = WindowChrome.new()
	_titlebar = _chrome.build(self)

	_grid = Control.new()
	add_child(_grid)
	_home_grid = _grid
	_home_tm = _tm
	_build_empty_state()

	var overlay = load("res://scenes/ui/toast_overlay.gd").new()
	add_child(overlay)
	# Workspace grids are added later (extra workspaces at restore time);
	# without a z bump these panels render UNDER them and appear broken.
	overlay.z_index = 100

	var pane_settings = load("res://scenes/ui/pane_settings_panel.gd").new()
	add_child(pane_settings)
	pane_settings.z_index = 100
	_tm._pane_settings_panel = pane_settings
	pane_settings.keyboard_released.connect(
		_on_overlay_keyboard_released.bind(pane_settings))
	# The pane settings can rename a pane's public id (that is how IPC
	# addresses it), and a typed duplicate would land *after* the pane was
	# attached — the one path that used to skip the uniqueness check. The id
	# is regenerated here, and the pane list redrawn because it shows it.
	# This handler is also the ONLY writer of the user-owned per-pane stores:
	# env (`PaneEnvStore`) and the Inspector's aim (`PaneInspectorStore`). Both
	# are keyed by the pane's id, so an entry follows a rename, and only what
	# the user set in the pane settings UI ever lands in a trusted store.
	pane_settings.settings_applied.connect(func(body: Control, settings: Dictionary, previous_id: String):
		_ensure_unique_attachment_id(body)
		if previous_id != "" and body.attachment_id != previous_id:
			_move_pane_env(previous_id, body.attachment_id)
			PaneInspectorStore.move_state(previous_id, body.attachment_id)
			# A companion follows its terminal by attachment id, so a rename
			# that left it on the old id would silence it: events carry the
			# new one and `receive_agent_event` drops them.
			_retarget_companions(body, previous_id)
		if settings.has("shell_env"):
			var env_text: String = str(settings.get("shell_env", "")).strip_edges()
			if env_text == "":
				PaneEnvStore.remove_env(body.attachment_id)
			else:
				PaneEnvStore.set_env(body.attachment_id, env_text)
		if body is InspectorPane and settings.has("system_prompt"):
			PaneInspectorStore.set_state(
				body.attachment_id,
				str(settings.get("system_prompt", "")),
				settings.get("auto_run", false) == true,
				settings.get("accept_concept_captures", false) == true)
		if body is WikiPane and settings.has("vault_path"):
			# The control socket's vault verbs answer only inside a registered
			# root, and this UI write is the only place a root becomes one: the
			# user pointed a pane at it. Restoring a tile, creating one over IPC
			# or a profile naming a path all leave the registry alone, so a
			# downloaded file (or an agent driving the API) cannot widen what
			# the next question may read.
			VaultRegistry.register(str(settings.get("vault_path", "")))
		_apply_active_workspace_view())

	# The one predicate the shortcut layer asks before it acts: an overlay owns
	# the keyboard, so only a window action may land while one is open.
	ShortcutManager.overlay_owns_keyboard = func() -> bool: return _keyboard_overlay() != null

	# Per-type keyboard shortcuts.
	#
	# Registered before the sidebar is built: its tooltips and help table spell
	# chords from this registry, so a registration after it would render as an
	# unbound action.
	for key in PaneTypes.ALL:
		var info = PaneTypes.ALL[key]
		var shortcut := str(info.get("shortcut", ""))
		if shortcut.strip_edges() == "":
			continue
		# The spawn itself activates (`_spawn_pane_into` -> `activate_pane`):
		# only terminals can take keyboard focus, so a read-only pane is still
		# recorded as active for "close active" and the sidebar accent, and the
		# keys go back to the window instead of raising an engine error.
		ShortcutManager.register("app:new_" + key, shortcut, func(): _spawn_pane(key))
	ShortcutManager.register("app:close_pane", "Ctrl+Shift+W", func(): _kill_last())
	ShortcutManager.register("app:toggle_sidebar", "Ctrl+Shift+B", _toggle_sidebar, true)
	ShortcutManager.register("app:toggle_palette", "Ctrl+Shift+P", _toggle_palette, true)
	ShortcutManager.register("app:focus_pane_chrome", "Ctrl+Shift+E", _focus_active_pane_chrome)
	ShortcutManager.register("app:focus_window_chrome", "Ctrl+Shift+A", _focus_window_chrome)
	ShortcutManager.register("app:focus_note_toolbar", "Ctrl+Shift+K", _focus_note_toolbar)
	ShortcutManager.register("app:focus_pane_toolbar", "Ctrl+Shift+L", _focus_pane_toolbar)
	ShortcutManager.register("app:toggle_fullscreen", "F11", _chrome.toggle_fullscreen, true)
	ShortcutManager.register("app:toggle_fullscreen_alt", "Ctrl+Shift+M", _chrome.toggle_fullscreen, true)
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

	# The guide is built before these registrations; its first show would
	# otherwise list only the bindings that existed then.
	if _shortcut_guide:
		_shortcut_guide.refresh()

	_build_sidebar()

	_status_bar = StatusBar.new()
	_status_bar.name = "StatusBar"
	add_child(_status_bar)

	ProfileManager.load_profiles()
	_wire_sidebar_signals()
	_refresh_profile_buttons()
	_wire_tm(_tm)
	_init_workspaces()

	# A quit request comes to us, not straight to the engine: panes holding
	# unsaved work get to ask before the window goes away (see `request_quit`).
	get_tree().auto_accept_quit = false

	# Push concepts to Rust engine — must wait for first frame (GDExtension ready)
	_push_concepts_deferred()
	# Reclaim scrollback rows of panes that no longer exist — same wait; needs
	# the restored workspace set and a started terminal for the FFI handle.
	_prune_history_deferred()

	SettingsManager.settings_changed.connect(_on_settings_changed)
	SettingsManager.appearance_changed.connect(_on_appearance_changed)
	# Concept changes are pushed by their owner (`ConceptManager`), one listener
	# per process: the engine's set is process-wide, so a per-workspace connect
	# both duplicated the push and collided across workspace instances.
	_on_settings_changed()
	# Forced: the call above ran while the scene was still building, so this is
	# the one that lands on a realized window.
	_apply_window_mode.call_deferred(true)
	if SettingsManager.cfg_window_mode == 0: _chrome.restore_position()

func _on_settings_changed():
	# Before anything measured: the scale changes the layout space every later
	# call in this chain (and the resize it triggers) lays out against. The
	# appearance resolves next, so every colour pushed below reads the palette
	# the settings just chose.
	SettingsManager.apply_ui_scale()
	SettingsManager.apply_appearance()
	# Every workspace, not just the visible one: hidden panes are live panes, and
	# a broadcast that skipped them left the next switch applying stale settings
	# to them. This is what the switch-time re-apply used to stand in for.
	for ws in _workspaces:
		for t in ws.tm.tiles:
			var body = ws.tm._find_body(t.wrapper)
			if body and body is TerminalPane:
				SettingsManager.apply_to_terminal(body)
	_apply_ui_colors()
	_sync_pane_titlebars()
	_apply_fps_setting()
	_apply_window_mode()

## A palette switch, wherever it came from: the Theme is rebuilt (every widget's
## colours and the role variations), the clear colour and the user-coloured
## chrome are re-pushed, terminals take their overlay colours again, and the
## custom-drawn surfaces repaint through the theme notification.
func _on_appearance_changed(_is_dark: bool) -> void:
	theme = UiTheme.build()
	RenderingServer.set_default_clear_color(UiPalette.active().BG)
	for ws in _workspaces:
		for t in ws.tm.tiles:
			var body = ws.tm._find_body(t.wrapper)
			if body and body is TerminalPane:
				SettingsManager.apply_to_terminal(body)
	_apply_ui_colors()

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
	if _status_bar:
		_status_bar.apply_chrome_colors()

## Every workspace's panes, not just the visible one: a title bar belongs to a
## live pane while its workspace is hidden, so the setting must reach it there
## (`_apply_ui_colors`'s pattern). The switch path no longer re-applies settings,
## so this is the only write that keeps a hidden bar from going stale.
func _sync_pane_titlebars():
	for ws in _workspaces:
		for t in ws.tm.tiles:
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
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_chrome.save_position()
		# auto_accept_quit is off (see _ready): the close request is ours to
		# answer, and the answer is the pane ask.
		request_quit()

# NOTE: We save in _exit_tree(), not NOTIFICATION_WM_CLOSE_REQUEST.
# WM_CLOSE_REQUEST does not fire when the Godot editor stops the game,
# only on actual window close in standalone builds. _exit_tree() fires
# reliably whenever the scene tree is torn down.

func _exit_tree():
	# The shortcut layer holds this workspace's predicate in a process-global
	# slot; a freed workspace must not be reachable from a later key press (a
	# test's tree, or a second workspace instance), so the slot goes back to the
	# neutral answer before anything else here runs.
	ShortcutManager.overlay_owns_keyboard = func() -> bool: return false
	_chrome.save_position()
	_save()
	SettingsManager.save_settings()

func _apply_window_mode(force := false):
	_chrome.apply_mode(force)
# ═══════════════════════════════════════════════════════════════════════
# Layout
# ═══════════════════════════════════════════════════════════════════════

## The screen a first launch shows. It is one scrollable guide, not two labels:
## the title, the live keycap demo (clickable, it starts the pane it shows) and
## every binding in `ShortcutCatalog` (read from the registry on every show). The
## shortcut text comes from `ShortcutManager.chord`, so it cannot drift from the
## binding it names. `_apply_layout` shows it exactly when the active workspace
## has no tiles.
func _build_empty_state():
	_empty_state = ScrollContainer.new()
	_empty_state.name = "EmptyState"
	_empty_state.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_empty_state.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_empty_state.follow_focus = true
	add_child(_empty_state)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	UiTheme.margins(margin, UiTokens.SPACE_XXL)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty_state.add_child(margin)

	_empty_center = CenterContainer.new()
	_empty_center.name = "Center"
	_empty_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_empty_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(_empty_center)

	_shortcut_guide = ShortcutGuide.new()
	_shortcut_guide.name = "ShortcutGuide"
	_shortcut_guide.configure(
		"Getting Started",
		func() -> Array:
			return ShortcutCatalog.rows(func(action: String): return ShortcutManager.chord(action)),
		func() -> Array:
			var out: Array = []
			for entry in ShortcutCatalog.new_pane_entries():
				var chord := ShortcutManager.chord(str(entry["action"]))
				if chord == "":
					continue
				out.append({
					"type": str(entry["action"]).trim_prefix("app:new_"),
					"chord": chord,
					"label": str(entry["label"]).trim_suffix(" pane"),
				})
			return out)
	_shortcut_guide.new_pane_requested.connect(func(type_name: String): _spawn_pane(type_name))
	_empty_center.add_child(_shortcut_guide)

func _apply_layout():
	if _grid == null: return
	var top_offset = TITLEBAR_HEIGHT if (_titlebar and _titlebar.visible) else 0.0
	var bottom_offset = StatusBar.HEIGHT if _status_bar else 0.0
	var m = _sidebar_bg.size.x if (_sidebar_bg and _sidebar_bg.visible) else 0.0

	_grid.offset_left = m; _grid.offset_right = 0
	_grid.offset_top = top_offset; _grid.offset_bottom = -bottom_offset
	_grid.anchor_left = 0.0; _grid.anchor_right = 1.0
	_grid.anchor_top = 0.0; _grid.anchor_bottom = 1.0

	if _empty_state:
		_empty_state.offset_left = m; _empty_state.offset_right = 0
		_empty_state.offset_top = top_offset; _empty_state.offset_bottom = -bottom_offset
		_empty_state.anchor_left = 0.0; _empty_state.anchor_right = 1.0
		_empty_state.anchor_top = 0.0; _empty_state.anchor_bottom = 1.0
		var was_visible := _empty_state.visible
		_empty_state.visible = _tm.tiles.is_empty()
		# A guide scrolled to the atlas must come back at its title, not where
		# the previous empty workspace left it.
		if _empty_state.visible and not was_visible:
			_empty_state.scroll_vertical = 0
		# The centre's floor is the viewport height, so a guide shorter than the
		# window is centred; a taller one keeps its own minimum and scrolls.
		if _empty_center:
			_empty_center.custom_minimum_size.y = maxf(0.0,
				_empty_state.size.y - UiTokens.SPACE_XXL * 2.0)
		if _shortcut_guide:
			_shortcut_guide.fit_width(_grid.size.x)

	if _status_bar:
		_status_bar.anchor_left = 0.0; _status_bar.anchor_right = 1.0
		_status_bar.anchor_top = 1.0; _status_bar.anchor_bottom = 1.0
		_status_bar.offset_top = -StatusBar.HEIGHT; _status_bar.offset_bottom = 0

	# The grid unit comes from PaneTypes — the same constant the sanitizer and
	# the drag math use. A local copy once drifted and sized every restored
	# pane several times the grid.
	var cw = maxf(_grid.size.x, 1.0) / PaneTypes.GRID
	var ch = maxf(_grid.size.y, 1.0) / PaneTypes.GRID
	for t in _tm.tiles:
		var x = t.col * cw; var y = t.row * ch
		var w = t.cspan * cw; var h = t.rspan * ch
		t.wrapper.offset_left = x; t.wrapper.offset_top = y
		t.wrapper.offset_right = x + w; t.wrapper.offset_bottom = y + h
		t.wrapper.anchor_left = 0.0; t.wrapper.anchor_right = 0.0
		t.wrapper.anchor_top = 0.0; t.wrapper.anchor_bottom = 0.0
		# The tile now holds the rect it is drawn at, so a pane that has not
		# started its child may start it at this size (a tile the grid has
		# never positioned is only the container's minimum).
		_tm.mark_tile_laid_out(t)

# ═══════════════════════════════════════════════════════════════════════
# Spawn / Kill — delegate to TerminalManager
# ═══════════════════════════════════════════════════════════════════════

## Live panes across every workspace: the number `MAX_LIVE_PANES` bounds.
## Tiles, not bodies, so a restore that is already placing wrappers counts
## against the ceiling exactly like a live pane does.
func _live_pane_count() -> int:
	var n := 0
	for ws in _workspaces:
		n += ws.tm.tiles.size()
	return n

## How many more panes may be created right now (never negative).
func _live_pane_room() -> int:
	return maxi(MAX_LIVE_PANES - _live_pane_count(), 0)

## "" while a pane may still be created, otherwise the refusal, naming the
## limit. The one decision behind every creation path: a toast, a caller's
## error and a restore notice all print this text, and the number in it comes
## from `MAX_LIVE_PANES` so none of them can state a different limit.
func _pane_ceiling_refusal() -> String:
	var live := _live_pane_count()
	if live < MAX_LIVE_PANES:
		return ""
	return "Pane limit reached: this window holds %d panes (the limit is %d). Close a pane to make room." % [live, MAX_LIVE_PANES]

func _spawn(shell := "") -> Control:
	return _spawn_pane("terminal", {"shell_command": shell})

func _spawn_pane(type_name: String, opts := {}, activate := true) -> Control:
	var ws := _active_workspace()
	if ws.is_empty():
		# Every pane belongs to a workspace: the first one the user creates
		# makes the implicit "Default" workspace.
		_add_workspace()
		ws = _active_workspace()
	if ws.is_empty():
		return null
	return _spawn_pane_into(ws, type_name, opts, activate)

func _spawn_pane_into(ws: Dictionary, type_name: String, opts := {}, activate := true) -> Control:
	var refused := _pane_ceiling_refusal()
	if refused != "":
		ToastManager.warn(refused)
		return null
	var tm: TerminalManager = ws.tm
	var body = tm.spawn_pane(type_name, opts, str(ws.get("cwd", "")))
	if body == null:
		ToastManager.warn("Cannot add pane — grid is full")
		return null
	var w = tm.tiles[-1].wrapper
	_add_body_to_grid_into(ws, w, body)
	# A pane the user asked for is the pane they are working in: record it and
	# hand it the keyboard. Only the active workspace can take focus (a hidden
	# terminal's `grab_focus` is dropped by the engine), and a restore passes
	# `false` so rebuilding a layout does not move the user's focus.
	if activate and ws.tm == _tm:
		activate_pane(body)
	return body

func _add_body_to_grid_into(ws: Dictionary, w: Control, body: Control):
	if ws.is_empty():
		return
	_attach_pane_into(ws, w, body)
	_sync_pane_titlebars()
	_apply_layout()
	_list()

## Answer a pane's `request_pane` (the file tree opening a file in a viewer,
## and any future origin). The type is held to the pane registry — the request
## is internal, but the spawn surface stays closed — and a `code_viewer`
## request for a file this workspace already shows is focused instead of
## duplicated: a viewer's scroll, selection and rendered/source mode belong to
## its document, so repointing one at another file is rejected, while a
## second view is a deliberate layout choice (spawn another viewer directly).
func _request_pane_into(ws: Dictionary, type_name: String, settings: Dictionary):
	if ws.is_empty() or not PaneTypes.ALL.has(type_name):
		return
	var path: String = str(settings.get("file_path", ""))
	if path != "" and (type_name == "code_viewer" or type_name == "media"):
		for t in ws.tm.tiles:
			var shown = ws.tm._find_body(t.wrapper)
			if type_name == "code_viewer" and shown is CodeViewerPane and shown.file_path == path:
				activate_pane(shown)
				return
			# A second media pane playing the same file would double the sound
			# and the decode work; focus the one that already holds it.
			if type_name == "media" and shown is MediaPane and shown.file_path == path:
				activate_pane(shown)
				return
	_spawn_pane_into(ws, type_name, settings)

# ── Close guards ───────────────────────────────────────────────────────
# Destroying a pane, or quitting the app, is the one action that cannot be
# undone, so every path that does it asks the panes first
# (`PaneBody.request_close`) and a "no" cancels the whole action.

## The bodies of one workspace, in tile order.
func _pane_bodies(ws: Dictionary) -> Array:
	var bodies := []
	if ws.is_empty():
		return bodies
	for t in ws.tm.tiles:
		var body = ws.tm._find_body(t.wrapper)
		if body != null:
			bodies.append(body)
	return bodies

## The panes that follow `body` inside `ws`: today the Reasoning pane's
## `source_attachment_id` link (the one type implementing `retarget_source`).
## Same-workspace only, mirroring `_retarget_companions`: a link into another
## workspace already observes nothing, and pulling it would take the pane from
## the workspace that owns it.
func _followers_of(body: Control, ws: Dictionary) -> Array[Control]:
	var out: Array[Control] = []
	if ws.is_empty() or not (body is TerminalPane):
		return out
	var id := str(body.get("attachment_id"))
	if id == "":
		return out
	for t in ws.tm.tiles:
		var other = ws.tm._find_body(t.wrapper)
		if other == null or other == body or not other.has_method("retarget_source"):
			continue
		if str(other.get("source_attachment_id")) == id:
			out.append(other)
	return out

## A label is numbered per TerminalManager, so an admitted pane can collide
## with one already there and label-addressed IPC then refuses every match as
## ambiguous. The admitted pane takes the next free label of its type. Only on
## collision: a label is how the user knows the pane.
func _renumber_label_if_taken(tm: TerminalManager, body: Control) -> void:
	var label := str(body.pane_label)
	for t in tm.tiles:
		var other = tm._find_body(t.wrapper)
		if other == null or other == body:
			continue
		if str(other.pane_label) == label:
			body.pane_label = tm._next_label(body._pane_type())
			return

## Move `bodies` (all in `src`) into `target`. Returns "" on success or a
## refusal; a refusal mutates nothing. No ceiling check (the live count is
## unchanged) and no Workspace Trust gate (nothing spawns).
func _move_panes_into(bodies: Array, src: Dictionary, target: Dictionary) -> String:
	if src.is_empty() or target.is_empty() or src.tm == target.tm:
		return "That pane is already in '%s'" % str(target.get("name", ""))
	if bodies.is_empty():
		return "No pane to move"
	for body in bodies:
		if not is_instance_valid(body) or src.tm._tile_index_of(body) == -1:
			return "Pane is no longer open"
	var target_tm: TerminalManager = target.tm
	if not target_tm.plan_adopt(bodies.size()):
		return "Cannot move %d pane(s): the grid in '%s' is full" % [
			bodies.size(), str(target.get("name", ""))]
	for i in bodies.size():
		var body: Control = bodies[i]
		var w: Control = src.tm.detach(body).wrapper
		body.backend_preserved = true
		w.reparent(target.grid)
		body.backend_preserved = false
		if not target_tm.adopt(w):
			push_error("movePane: adopt failed after a successful plan")
		_renumber_label_if_taken(target_tm, body)
		# The scan skips a record whose source id still matches, so a moved
		# pane would never be re-primed in its new workspace and its badge
		# would freeze.
		_agent_state_primed.erase(body.get_instance_id())
	_apply_layout()
	_list()
	_update_workspace_ui()
	_sync_pane_titlebars()
	_focus_owner_cache = null
	_focus_body_cache = null
	_save_workspaces_to_store()
	if _tm.tiles.is_empty():
		_tm.last_body = null
	elif _tm.last_body == null or not is_instance_valid(_tm.last_body):
		var fb := _fallback_active_body()
		if fb != null:
			activate_pane(fb)
	_refresh_status_bar()
	return ""

## The GUI entry: this pane plus the panes that follow it, addressed by
## workspace name because an index would repoint if a workspace closed.
func _move_panes_to(body: Control, target_name: String) -> void:
	var src := _workspace_for_body(body)
	if src.is_empty():
		return
	var target: Dictionary = {}
	for ws in _workspaces:
		if str(ws.name) == target_name:
			target = ws
			break
	if target.is_empty():
		ToastManager.warn("Workspace '%s' no longer exists" % target_name)
		return
	var moved: Array = [body]
	moved.append_array(_followers_of(body, src))
	var refusal := _move_panes_into(moved, src, target)
	if refusal != "":
		ToastManager.warn(refusal)
		return
	var labels: Array[String] = []
	for b in moved:
		labels.append(str(b.pane_label))
	ToastManager.info("Moved %s to \"%s\"" % [" + ".join(labels), target_name])
	_warn_after_move(moved, target)

## Policy A moves a terminal with its followers; the two links it cannot infer
## are said out loud instead: a follower left without its source (moved on its
## own), and an auto-run Inspector that starts answering the target
## workspace's captures.
func _move_notes(moved: Array, target: Dictionary) -> Array[String]:
	var notes: Array[String] = []
	var target_ids := {}
	var other_terminals := false
	for t in target.tm.tiles:
		var b = target.tm._find_body(t.wrapper)
		if b == null:
			continue
		target_ids[str(b.get("attachment_id"))] = true
		if b is TerminalPane and moved.find(b) == -1:
			other_terminals = true
	for body in moved:
		if not body.has_method("retarget_source"):
			continue
		var src_id := str(body.get("source_attachment_id"))
		if src_id != "" and not target_ids.has(src_id):
			notes.append("%s watches %s, which is in another workspace: it will observe nothing here." % [
				str(body.pane_label), src_id])
	if other_terminals:
		for body in moved:
			if str(body._pane_type()) == "inspector" and bool(body.get("auto_run")):
				notes.append("%s auto-runs, so it will answer captures from \"%s\"." % [
					str(body.pane_label), str(target.name)])
	return notes

func _warn_after_move(moved: Array, target: Dictionary) -> void:
	var notes := _move_notes(moved, target)
	if not notes.is_empty():
		ToastManager.warn(" ".join(notes), 8.0)

## Every pane of every workspace — hidden workspaces keep live panes.
func _all_pane_bodies() -> Array:
	var bodies := []
	for ws in _workspaces:
		bodies.append_array(_pane_bodies(ws))
	return bodies

## Ask `bodies` in order whether they may be destroyed, then run `next`. A
## pane that answers no stops the walk: `declined` runs (when given) and
## `next` never does, so the action behind the walk is cancelled as a whole.
##
## Two questions, in a deliberate order. Stopping processes still running in
## the panes is the *action's* hazard, so it is asked once for the whole set
## (`_ask_running_then`) — a workspace close must not raise one dialog per
## terminal. What a pane must ask about itself (the wiki's Save/Discard) goes
## through the per-pane contract. `ask_running` is false only for an IPC
## action, whose caller cannot answer a dialog and has already been refused
## for unsaved work: naming the action is its consent to stop processes.
func _ask_close_then(
		bodies: Array, next: Callable, declined := Callable(),
		ask_running := true, action := "Closing", qualify_entries := true) -> void:
	if ask_running:
		_ask_running_then(
			bodies, func(): _ask_close_step(bodies, 0, next, declined), declined,
			action, qualify_entries)
	else:
		_ask_close_step(bodies, 0, next, declined)

## One consent for the processes a whole action would stop.
##
## `has_running_work` is exact where the platform can tell (Unix foreground
## process group) and conservative where it cannot (Windows: a live shell).
## A clean action calls `next` synchronously, so nothing is shown for a close
## that loses nothing.
##
## `action` is the caller's phrase for what is about to happen ("Closing the
## 'git' workspace", "Quitting"); `qualify_entries` is false when that phrase
## already names the workspace, so the pane lines do not repeat it.
func _ask_running_then(
		bodies: Array, next: Callable, declined := Callable(),
		action := "Closing", qualify_entries := true) -> void:
	var busy: Array = []
	var total := 0
	for body in bodies:
		if not is_instance_valid(body):
			continue
		total += 1
		if body.has_running_work():
			busy.append(body)
	if busy.is_empty():
		next.call()
		return
	var names := PackedStringArray()
	var shown := mini(busy.size(), RUNNING_ASK_MAX_NAMES)
	for i in shown:
		var body = busy[i]
		var display := str(body.call("display_name")) if body.has_method("display_name") else ""
		var ws_name := ""
		if body is Control:
			ws_name = str(_workspace_for_body(body).get("name", ""))
		names.append(running_ask_entry(
			str(body.get("pane_label")), display, ws_name, qualify_entries))
	if busy.size() > shown:
		names.append("…and %d more" % (busy.size() - shown))
	var dialog := AppDialog.confirm(self, "Stop running processes?")
	dialog.name = "RunningWorkConfirm"
	AppDialog.set_text(dialog, (
		"%s\n\n%s\n\nClose anyway?"
		% [running_ask_intro(action, busy.size(), total), "\n".join(names)]))
	dialog.ok_button_text = "Close anyway"
	dialog.cancel_button_text = "Cancel"
	dialog.confirmed.connect(func():
		dialog.hide()
		dialog.queue_free()
		next.call()
	)
	dialog.canceled.connect(func():
		dialog.hide()
		dialog.queue_free()
		if declined.is_valid():
			declined.call()
	)
	AppDialog.popup(dialog)

func _ask_close_step(bodies: Array, index: int, next: Callable, declined: Callable) -> void:
	while index < bodies.size() and not is_instance_valid(bodies[index]):
		index += 1  # freed while an earlier pane was asking
	if index >= bodies.size():
		next.call()
		return
	var body = bodies[index]
	body.request_close(func(proceed: bool):
		if not proceed:
			if declined.is_valid():
				declined.call()
			return
		_ask_close_step(bodies, index + 1, next, declined)
	)

## Quit the app — the one quit path, reached by the window manager's close
## request, the titlebar's close button and the shutdown flag. Panes holding
## unsaved work are asked first, and a Cancel cancels the quit. A second
## request during the walk is ignored rather than stacking dialogs; the flag
## clears when the walk ends, so a request after a cancelled one still works.
func request_quit() -> void:
	if _quit_asking:
		return
	_quit_asking = true
	_ask_close_then(
		_all_pane_bodies(),
		func():
			_quit_asking = false
			quit_action.call(),
		func(): _quit_asking = false,
		true, "Quitting",
	)

## Close one pane the user asked to close. Stopping a running command and
## discarding unsaved work are both questions; a Cancel leaves the pane.
func _kill(body: Control):
	var ws := _workspace_for_body(body)
	if ws.is_empty():
		return
	_ask_close_then([body], func(): _kill_now(body))

func _kill_now(body: Control):
	# `_refresh_status_bar` keeps last_body synced to the focus owner, so this
	# tells us whether the pane being closed was the one holding the keyboard;
	# the second test also covers a closed pane's own title-bar button holding
	# the focus while another pane is "active".
	var ws := _workspace_for_body(body)
	if ws.is_empty():
		return
	var held_focus: bool = ws.tm.last_body == body or _focus_owner_in(body)
	# The user discarded this Inspector pane, so its stored aim goes with it: a
	# later pane that reuses the id starts from the defaults, not from an
	# instruction the user removed. Only this explicit-close path removes it —
	# restart, profile activation, workspace close and layout restore reset the
	# manager directly (`tm.reset()`), so the aim still survives those.
	if body is InspectorPane:
		PaneInspectorStore.remove_state(str(body.attachment_id))
	ws.tm.kill(body)
	_close_pane_settings_for(body)
	_apply_layout()
	if held_focus:
		# Otherwise the freed node takes focus with it and typing reaches
		# nothing until the user clicks a pane. The survivor is the last pane in
		# tile order - the one the tiling logic grows into the closed pane's
		# space - and it is activated before `_list()` so the sidebar accent
		# names it in this frame. A read-only survivor still becomes the active
		# pane (accent, status bar, "close active") and releases the keyboard
		# itself, the same rule a click applies.
		var survivor := _last_pane_body(ws)
		if survivor != null:
			activate_pane(survivor)
	_list()

## The last pane of `ws` in tile order — the survivor when the active pane
## closes (the tiling logic grows that tile into the freed space). Any type
## qualifies: a read-only pane owns the sidebar accent and "close active".
func _last_pane_body(ws: Dictionary) -> Control:
	if ws.is_empty():
		return null
	var tiles: Array = ws.tm.tiles
	for i in range(tiles.size() - 1, -1, -1):
		var body = ws.tm._find_body(tiles[i].wrapper)
		if body != null:
			return body
	return null

## Whether the keyboard focus owner is `body` or a widget inside it. A pane can
## be closed while its own title-bar button holds the focus, and that pane is
## the one the user is working in even when `last_body` names another.
func _focus_owner_in(body: Control) -> bool:
	var owner := get_viewport().gui_get_focus_owner()
	return owner != null and (owner == body or body.is_ancestor_of(owner))

## Close the pane settings popup when its target pane is torn down. The
## panel also self-closes via _process when its target is freed by other
## paths (swap, reset, restore, workspace close) — this is the immediate,
## explicit close on the primary kill path.
func _close_pane_settings_for(body: Control):
	var panel: Control = _tm._pane_settings_panel
	if panel and panel.visible and panel._target == body:
		panel.close()

## Change a pane's type. The old body is destroyed by the swap, so it answers
## first — for a running command as well as unsaved work.
func _swap_pane(body: Control, new_type_name: String):
	var ws := _workspace_for_body(body)
	if ws.is_empty():
		return
	_ask_close_then([body], func(): _swap_pane_now(body, new_type_name), Callable(), true, "Switching the pane type")

func _swap_pane_now(body: Control, new_type_name: String):
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
	# The swapped-in body is the pane the user just acted on: record it and
	# apply the one focus rule (a terminal takes the keyboard, a read-only
	# pane releases it).
	activate_pane(new_body)

func _kill_last():
	if not is_instance_valid(_tm.last_body):
		return
	_kill(_tm.last_body)

## The sidebar row's one menu — the same builder the title bar's overflow button
## opens, so both surfaces list the same actions and mark the same current type.
func _on_pane_menu(body: Control, source_btn: Button):
	_tm.show_pane_actions_popup(body, self, source_btn.get_screen_position() + Vector2(0, source_btn.size.y))

## The reset primitive: every pane of the active workspace goes, no asking.
## Only the guarded entries below and the layout-rebuild internals call it.
func _reset_now():
	_tm.reset()
	_apply_layout()
	_list()

## The action phrase for a close-all: the palette's "Close all panes" names no
## workspace, so the confirmation has to.
func _active_close_all_action() -> String:
	var ws_name := A11y.one_line(str(_active_workspace().get("name", "")))
	return "Closing all panes in the '%s' workspace" % ws_name

## Reset the active workspace's panes — the user-facing paths (sidebar,
## shortcut, palette) and profile activation ask first.
func _reset():
	_ask_close_then(
		_pane_bodies(_active_workspace()), _reset_now, Callable(), true,
		_active_close_all_action(), false)

## User-facing reset: clears the active workspace's panes AND the
## profile-accent state (a reset layout is no longer "that profile").
func _do_reset():
	_ask_close_then(
		_pane_bodies(_active_workspace()), _do_reset_now, Callable(), true,
		_active_close_all_action(), false)

func _do_reset_now():
	_reset_now()
	var ws := _active_workspace()
	if not ws.is_empty():
		ws["profile"] = ""
	_active_profile = ""
	_refresh_profile_buttons()

# ═══════════════════════════════════════════════════════════════════════
# Workspaces — independent pane sets, keep-alive
# ═══════════════════════════════════════════════════════════════════════

func _update_workspace_ui():
	if _sidebar:
		_sidebar.update_workspace_list(_workspace_names(), _active, _workspace_dirs())

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
	_on_duplicate_rename(id, replacement)

## A collision rename is not a user gesture: the user-owned state keyed by the
## old id is carried to the new one, and the change is reported (the id shows
## in the pane settings and addresses the pane over IPC). Shared by the
## attach-time check and the restore pre-pass so both paths behave the same.
func _on_duplicate_rename(old_id: String, new_id: String):
	_carry_pane_env(old_id, new_id)
	PaneInspectorStore.copy_state(old_id, new_id)
	ToastManager.warn("Duplicate pane id '%s' renamed to '%s'" % [old_id, new_id])

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

## Resolve every restored tile's `attachment_id` before any body exists, then
## rewrite the set's companion references through the same map.
##
## A profile can be activated in more than one workspace, so its saved ids
## (e.g. `omp-terminal`) collide with the instance already live elsewhere. The
## attach path renames the duplicate, but by then a later tile may already have
## stored the original id as its `source_attachment_id`: the Reasoning pane
## would follow the *other* workspace's terminal. Inside a workspace the first
## tile keeps a repeated id, matching IPC's first-match resolution.
func _resolve_tile_ids(plans: Array[Dictionary]):
	var reserved := {}
	for ws in _workspaces:
		if ws.is_empty() or not ws.has("tm"):
			continue
		for t in ws.tm.tiles:
			var other = ws.tm._find_body(t.wrapper)
			if other != null:
				reserved[str(other.get("attachment_id"))] = true
	var remap := {}
	for plan in plans:
		var settings: Dictionary = plan["tile"]["settings"]
		var id := str(settings.get("attachment_id", ""))
		if id == "":
			continue  # `apply_settings` generates one; nothing can reference it
		if not reserved.has(id):
			reserved[id] = true
			continue
		var replacement := PaneTypes.generate_attachment_id()
		for _i in 32:
			if not reserved.has(replacement):
				break
			replacement = PaneTypes.generate_attachment_id()
		reserved[replacement] = true
		settings["attachment_id"] = replacement
		_on_duplicate_rename(id, replacement)
		if not remap.has(id):
			remap[id] = replacement
	if remap.is_empty():
		return
	for plan in plans:
		var settings: Dictionary = plan["tile"]["settings"]
		var source := str(settings.get("source_attachment_id", ""))
		if source != "" and remap.has(source):
			settings["source_attachment_id"] = remap[source]

## A collision rename is not a user gesture, so the old id's env is *copied*:
## the entry still belongs to the pane holding that id in the other workspace,
## and both instances of a profile's logical pane should spawn with the
## environment the user set for it. Runs before the body enters the tree, where
## `_ready` reads the store (a terminal's spawn env).
func _carry_pane_env(old_id: String, new_id: String):
	if old_id == "" or new_id == "" or old_id == new_id:
		return
	if not PaneEnvStore.has_env(old_id) or PaneEnvStore.has_env(new_id):
		return
	PaneEnvStore.set_env(new_id, PaneEnvStore.env_for(old_id))

## A rename the user made in Pane Settings moves the entry: the old id is no
## longer the pane's, so it must not carry the env any more. The companion
## inspector store moves separately (`PaneInspectorStore.move_state`).
func _move_pane_env(old_id: String, new_id: String):
	if old_id == "" or new_id == "" or old_id == new_id:
		return
	var own_env := PaneEnvStore.env_for(old_id)
	PaneEnvStore.remove_env(old_id)
	if own_env != "":
		PaneEnvStore.set_env(new_id, own_env)

## Re-point the companions that follow a pane renamed in Pane Settings.
##
## The follow link (`source_attachment_id`) is a display link, not an IPC id,
## so it is rewritten inside the renamed pane's own workspace only: the same
## profile can be live in another workspace under its own ids, and a rename
## here must not steal that workspace's companion. Companions opt in by
## implementing `retarget_source` - the pane decides whether a rename keeps its
## session state, which `apply_settings` (a *different* source) resets.
func _retarget_companions(body: Control, previous_id: String):
	var new_id := str(body.attachment_id)
	if previous_id == "" or new_id == "" or new_id == previous_id:
		return
	var ws := _workspace_for_body(body)
	if ws.is_empty():
		return
	for t in ws.tm.tiles:
		var other = ws.tm._find_body(t.wrapper)
		if other == null or other == body:
			continue
		if not other.has_method("retarget_source"):
			continue
		if str(other.get("source_attachment_id")) != previous_id:
			continue
		other.retarget_source(new_id)

## Single choke point where a pane enters a workspace: adds the wrapper to
## the grid, wires activation tracking, and (for terminals) the dynamic
## title. Spawn, restore, and swap all funnel through here so a new pane
## type is wired correctly everywhere.
func _attach_pane_into(ws: Dictionary, w: Control, body: Control):
	_ensure_unique_attachment_id(body)
	# The id is final now, so the user's own per-pane state (the Inspector's
	# prompt and switches) can be overlaid on the saved settings. Every entry
	# route — spawn, restore, type swap — comes through here.
	body.apply_user_state()
	ws.grid.add_child(w)
	_wire_pane_activation(body)
	# Panes never spawn panes: a body that needs another pane emits
	# `request_pane` and this workspace — the only spawner — answers it.
	# Identity, not the workspace dictionary: a pane can move to another grid.
	body.request_pane.connect(func(type_name: String, settings: Dictionary):
		_request_pane_for(body, type_name, settings)
	)
	if body is TerminalPane:
		body.title_changed.connect(func(t: String):
			var lbl = w.get_node_or_null("BodyVBox/TitleBar/TitleLabel")
			if lbl: lbl.text = " " + t
		)
		# A pane answer is held until its child starts, so the outcome comes
		# back through here: success releases the answer, a refusal answers it
		# with the reason and closes the tile. Both are emitted a frame after
		# the start attempt, outside the container sort that caused it.
		body.child_started.connect(func(): _on_pane_child_started(body))
		body.child_start_failed.connect(func(reason: String): _on_pane_child_failed(body, reason))
		# Agent-state contract: this terminal is the source of its own state.
		# The state itself is dispatched by `_prime_new_pane_observers` /
		# `_dispatch_agent_state` — panes are primed by the scan, not here, so
		# every pane-entry route ends up informed.
		body.agent_state_changed.connect(func(state: String):
			_dispatch_agent_state_for(body, state)
		)

func _wire_pane_activation(body: Control):
	# Pane activation on plain clicks is handled in _input via wrapper
	# hit-testing — container ancestors skip gui_input propagation, so
	# wiring the wrapper does not work. This covers the focusable case.
	body.focus_entered.connect(func(): _record_active_pane(body))

## Record `body` as its own workspace's active pane. The pane decides the
## workspace, so nothing has to be rewired when it moves between grids.
func _record_active_pane(body: Control) -> void:
	var bws := _workspace_for_body(body)
	if not bws.is_empty():
		bws.tm.last_body = body

func _request_pane_for(body: Control, type_name: String, settings: Dictionary) -> void:
	var ws := _workspace_for_body(body)
	if ws.is_empty():
		return
	_request_pane_into(ws, type_name, settings)

func _dispatch_agent_state_for(body: Control, state: String) -> void:
	var ws := _workspace_for_body(body)
	if ws.is_empty():
		return
	_dispatch_agent_state(ws, str(body.attachment_id), state)

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

## Wire a manager's three callbacks to workspace methods.
##
## These are bound methods, never lambdas. A lambda that captures `tm` is stored
## *on* `tm`, and `TerminalManager` is `RefCounted`: that is a reference cycle
## the engine can never release, so every closed workspace tab and every exit
## leaked the manager, its `TileDrag` and the scripts they hold (13 leaked
## instances, 85 unclaimed StringNames). `on_open_pane_settings` receives the
## manager as an argument for the same reason - no capture needed.
func _wire_tm(tm: TerminalManager):
	tm.on_close = _on_pane_closed
	tm.on_swap = _swap_pane
	tm.on_open_pane_settings = _open_pane_settings_for
	tm.on_move_panes = _append_move_menu
	# Every manager, not just the home pair's: the first workspace a session
	# creates is no longer workspace 0, so a manager without this connection
	# would stop relayouting after a divider drag.
	tm.tiles_resized.connect(_apply_layout)

## The pane menu's "Move to workspace" submenu. Targets are addressed by
## workspace name, not index: a close or rename while the menu is open would
## repoint an index.
func _append_move_menu(menu: PopupMenu, body: Control) -> void:
	var src := _workspace_for_body(body)
	if src.is_empty() or _workspaces.size() < 2:
		return
	var sub := PopupMenu.new()
	sub.name = "MoveToWorkspaceMenu"
	menu.add_child(sub)
	# `add_submenu_item`, not `set_item_submenu`: on 4.7.2 the setter accepts the
	# name and does nothing (the item opens no submenu), while the add form
	# binds it. No icon: the shared builder's item would need the setter.
	menu.add_submenu_item("Move to workspace", sub.name)
	menu.set_item_tooltip(menu.item_count - 1,
		"Move this pane, and the panes that follow it, to another workspace.")
	var followers := _followers_of(body, src)
	for ws in _workspaces:
		if ws.tm == src.tm:
			continue
		var label := "Move to \"%s\"" % str(ws.name)
		if not followers.is_empty():
			var names: Array[String] = []
			for f in followers:
				names.append(str(f.pane_label))
			label += " (with %s)" % " + ".join(names)
		sub.add_item(label)
		sub.set_item_metadata(sub.item_count - 1,
			{"kind": "move", "workspace": str(ws.name)})
	sub.index_pressed.connect(func(idx: int):
		var meta = sub.get_item_metadata(idx)
		menu.queue_free()
		if not (meta is Dictionary):
			return
		_move_panes_to(body, str(meta.get("workspace", "")))
	)

func _on_pane_closed(body: Control) -> void:
	_kill(body)

## The pane settings popup and the global settings panel are sibling overlays;
## opening one closes the other so they never stack.
func _open_pane_settings_for(tm: TerminalManager, body: Control) -> void:
	if _settings_panel and _settings_panel.visible:
		_settings_panel.close()
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

func _new_workspace_container(ws_name: String, ws_cwd := "") -> Dictionary:
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
	return {"name": ws_name, "grid": grid, "tm": tm, "profile": "", "cwd": ws_cwd}

func _workspace_names() -> Array[String]:
	var out: Array[String] = []
	for ws in _workspaces:
		out.append(str(ws.name))
	return out

func _workspace_dirs() -> Array[String]:
	var out: Array[String] = []
	for ws in _workspaces:
		out.append(str(ws.get("cwd", "")))
	return out

func _next_workspace_number() -> int:
	var max_n := 0
	for ws in _workspaces:
		var ws_name: String = str(ws.name)
		if ws_name.begins_with("Workspace "):
			max_n = maxi(max_n, ws_name.substr("Workspace ".length()).to_int())
	return max_n + 1

## The pane a workspace should activate when it has no remembered one — at
## launch, on switching to a workspace that was restored but never visited,
## and after a profile rebuild. A terminal wins because only terminals take
## keyboard focus: activating the first tile of a read-only-first layout would
## leave the first keystroke nowhere. The first tile is the fallback so a
## read-only workspace still has an active pane (sidebar accent, status bar,
## "close active").
func _fallback_active_body() -> Control:
	var first: Control = null
	for t in _tm.tiles:
		var body = _tm._find_body(t.wrapper)
		if body == null:
			continue
		if first == null:
			first = body
		if body is TerminalPane:
			return body
	return first

func _apply_active_workspace_view():
	if _workspaces.is_empty():
		_apply_empty_workspace_view()
		return
	_tm = _workspaces[_active].tm
	_grid = _workspaces[_active].grid
	for i in _workspaces.size():
		_workspaces[i].grid.visible = (i == _active)
		_workspaces[i].grid.process_mode = Node.PROCESS_MODE_INHERIT if i == _active else Node.PROCESS_MODE_DISABLED
	_update_workspace_ui()
	# The profile accent belongs to the workspace, not the app: a profile
	# activated in W1 must not stay lit while W2 (which never activated one)
	# is active. Each workspace records its own profile name, and every
	# switch, creation and restore re-derives the accent from it.
	var active_ws := _active_workspace()
	_active_profile = str(active_ws.get("profile", "")) if not active_ws.is_empty() else ""
	_refresh_profile_buttons()
	_apply_layout()
	_list()
	_sync_pane_titlebars()
	_refresh_status_bar()
	# The same rule as every other activation path: a terminal takes the
	# keyboard, a read-only pane releases it. A bare `grab_focus()` here raised
	# an engine error for the latter on every workspace switch. When the
	# workspace has no remembered pane, pick its first terminal: `last_body`
	# is only ever set by a click, a spawn, or a focus event, and startup sets
	# none of them — leaving the first keystroke after launch with nowhere to
	# go (UX-01).
	var body: Control = _tm.last_body
	if body == null or not is_instance_valid(body):
		body = _fallback_active_body()
	if body:
		activate_pane(body)

## The state with no workspace: the home pair is an empty host, the guide owns
## the content area, and the sidebar shows no rows and no close-all trash.
func _apply_empty_workspace_view():
	_active = -1
	_tm = _home_tm
	_grid = _home_grid
	_grid.visible = false
	_grid.process_mode = Node.PROCESS_MODE_DISABLED
	_active_profile = ""
	_refresh_profile_buttons()
	_update_workspace_ui()
	_apply_layout()
	_list()
	_refresh_status_bar()

func _switch_workspace(idx: int):
	if _workspaces.is_empty() or idx < 0 or idx >= _workspaces.size() or idx == _active:
		return
	_save_workspaces_to_store()
	_active = idx
	# A view change only. Every setting already reached the hidden workspaces'
	# panes through `_on_settings_changed`; re-applying them here pushed the
	# palette into grids that had not changed and, through the window mode, paid
	# a window-server round trip on every switch (the measured second in
	# "A workspace switch costs about a second on the daily-use set").
	_apply_active_workspace_view()

func _add_workspace():
	if _workspaces.size() >= MAX_WORKSPACES:
		ToastManager.warn("Maximum %d workspaces" % MAX_WORKSPACES)
		return
	# The first workspace a session creates is the default one; there is no
	# seeded workspace to inherit a name or a directory from.
	var ws_name = IMPLIED_WORKSPACE_NAME if _workspaces.is_empty() \
		else "Workspace %d" % _next_workspace_number()
	# A new workspace starts where the current one points, the way a new
	# terminal tab does; the folder menu changes it independently afterwards.
	var ws = _new_workspace_container(ws_name, str(_active_workspace().get("cwd", "")))
	_workspaces.append(ws)
	# Blank slate: no auto-spawned terminal — the user decides what fills it.
	_switch_workspace(_workspaces.size() - 1)

## A blank workspace for `profile`, switched to so `_tm`, the grid and the
## sidebar follow it. Named after the profile (a second one from the same
## profile gets " 2", " 3" …) and pointing where the current workspace points,
## the same way a new tab inherits its directory. Returns {} at the cap; with
## no active workspace it simply starts without an inherited directory.
func _create_workspace_for_profile(profile: Dictionary) -> Dictionary:
	if _workspaces.size() >= MAX_WORKSPACES:
		return {}
	var taken := {}
	for ws in _workspaces:
		taken[str(ws.name)] = true
	var ws := _new_workspace_container(
		WorkspaceStore.unique_name(str(profile.get("name", "Profile")), taken),
		str(_active_workspace().get("cwd", "")))
	_workspaces.append(ws)
	_switch_workspace(_workspaces.size() - 1)
	return ws

func _close_workspace(idx: int):
	if _workspaces.is_empty() or idx < 0 or idx >= _workspaces.size():
		return
	var ws: Dictionary = _workspaces[idx]
	var ws_name := A11y.one_line(str(ws.get("name", "")))
	_ask_close_then(
		_pane_bodies(ws), func(): _close_workspace_now(idx), Callable(), true,
		"Closing the '%s' workspace" % ws_name, false)

func _close_workspace_now(idx: int):
	# Re-checked: the ask is deferred, so the list it was made against may
	# have moved on (another close, a restore) by the time it is answered.
	if _workspaces.is_empty() or idx < 0 or idx >= _workspaces.size():
		return
	var ws: Dictionary = _workspaces[idx]
	_workspaces.remove_at(idx)
	ws.tm.reset()
	# The home pair is the empty host for the zero-workspace state; it is
	# never freed. Every other workspace owns its grid.
	if ws.grid != _home_grid:
		ws.grid.queue_free()
	if _workspaces.is_empty():
		_apply_empty_workspace_view()
		_save_workspaces_to_store()
		return
	if idx == _active:
		_active = clampi(idx, 0, _workspaces.size() - 1)
		_apply_active_workspace_view()
		_on_settings_changed()
	elif idx < _active:
		_active -= 1
	_update_workspace_ui()
	_save_workspaces_to_store()

## The Workspaces title row's close-all. Every pane in every workspace is asked
## first, the same walk a workspace close uses; the entries name their workspace.
func _close_all_workspaces():
	if _workspaces.is_empty():
		return
	_ask_close_then(
		_all_pane_bodies(), _close_all_workspaces_now, Callable(), true,
		"Closing all workspaces")

func _close_all_workspaces_now():
	for ws in _workspaces:
		ws.tm.reset()
		if ws.grid != _home_grid:
			ws.grid.queue_free()
	_workspaces.clear()
	_home_tm.reset()
	_apply_empty_workspace_view()
	_save_workspaces_to_store()

## The workspace More menu's Clear Workspace: empty `idx` without switching to
## it. The ask names the workspace and walks its panes (running work and unsaved
## edits), exactly as closing that workspace would.
func _clear_workspace(idx: int):
	if idx < 0 or idx >= _workspaces.size():
		return
	var ws: Dictionary = _workspaces[idx]
	var ws_name := A11y.one_line(str(ws.get("name", "")))
	_ask_close_then(
		_pane_bodies(ws), func(): _clear_workspace_now(ws), Callable(), true,
		"Closing all panes in the '%s' workspace" % ws_name, false)

func _clear_workspace_now(ws: Dictionary):
	if _workspaces.find(ws) == -1:
		return
	ws.tm.reset()
	# A cleared workspace is no longer the profile it was built from, the same
	# rule `_do_reset_now` applies to the active one.
	ws["profile"] = ""
	if ws.tm == _tm:
		_active_profile = ""
		_apply_active_workspace_view()
	_save_workspaces_to_store()

## The one workspace-row menu. Built per open and freed on close (the
## `show_pane_actions_popup` pattern), so it always names the current directory.
func _on_workspace_menu(idx: int, source_btn: Button):
	if idx < 0 or idx >= _workspaces.size():
		return
	var ws: Dictionary = _workspaces[idx]
	var menu := PopupMenu.new()
	menu.name = "WorkspaceActionsMenu"
	var dir := str(ws.get("cwd", ""))
	var dir_tip := "Working directory: %s" % (
		dir if dir != "" else "default (gpty's own directory)")
	MenuItems.add(menu, Icons.PENCIL, "Rename Workspace",
		"Rename '%s'" % str(ws.get("name", "")),
		{"kind": "rename", "index": idx})
	MenuItems.add(menu, Icons.FOLDER, "Set Directory", dir_tip,
		{"kind": "cwd", "index": idx})
	MenuItems.add(menu, Icons.DELETE, "Clear Workspace",
		"Close every pane in '%s'" % str(ws.get("name", "")),
		{"kind": "clear", "index": idx})
	menu.index_pressed.connect(func(i: int):
		var meta = menu.get_item_metadata(i)
		menu.queue_free()
		if not (meta is Dictionary):
			return
		var action: Dictionary = meta
		var at := int(action.get("index", -1))
		if at < 0 or at >= _workspaces.size():
			return
		match str(action.get("kind", "")):
			"rename": _sidebar.begin_workspace_rename.call_deferred(at)
			"cwd": _open_workspace_cwd_dialog(at)
			"clear": _clear_workspace(at)
	)
	add_child(menu)
	menu.position = source_btn.get_screen_position() + Vector2(0, source_btn.size.y)
	menu.reset_size()
	menu.popup()
	menu.popup_hide.connect(menu.queue_free)

func _rename_workspace(idx: int, new_name: String):
	if _workspaces.is_empty() or idx < 0 or idx >= _workspaces.size():
		return
	var clean := WorkspaceStore.sanitize_name(new_name)
	if _workspaces[idx].name == clean:
		return  # no-op — also absorbs the duplicate blur/enter commit
	_workspaces[idx].name = clean
	_update_workspace_ui()
	_save_workspaces_to_store()

## Pick a workspace's default directory. It applies to terminals spawned
## after the change — a freshly activated profile included — and never moves
## a live shell, so the user's running work is untouched.
func _open_workspace_cwd_dialog(idx: int):
	if idx < 0 or idx >= _workspaces.size():
		return
	var ws: Dictionary = _workspaces[idx]
	var dialog := AppDialog.picker(self, "Working directory for %s" % str(ws.get("name", "")),
		FileDialog.FILE_MODE_OPEN_DIR)
	var start := str(ws.get("cwd", ""))
	if start == "":
		start = OS.get_environment("HOME")
	if start == "":
		start = OS.get_environment("USERPROFILE")
	if start != "" and DirAccess.dir_exists_absolute(start):
		dialog.current_dir = start
	dialog.add_button("Use default", true, "default")
	dialog.custom_action.connect(func(action: StringName):
		if action == &"default":
			_set_workspace_cwd(idx, "")
			dialog.queue_free()
	)
	dialog.dir_selected.connect(func(dir: String):
		_set_workspace_cwd(idx, dir)
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	AppDialog.popup(dialog, 0.6)

func _set_workspace_cwd(idx: int, dir: String):
	if idx < 0 or idx >= _workspaces.size():
		return
	var clean := WorkspaceStore.sanitize_cwd(dir)
	if dir != "" and clean == "":
		ToastManager.warn("That working directory is not a usable absolute path")
		return
	if clean != "" and not DirAccess.dir_exists_absolute(clean):
		ToastManager.warn("Working directory does not exist: %s" % clean)
		return
	var ws: Dictionary = _workspaces[idx]
	if str(ws.get("cwd", "")) == clean:
		return
	# A directory is a trust input only where the spawn is already untrusted:
	# the plan keys this workspace will restore carry its directory (see
	# `PaneTypes.tile_plan_key`), so a new directory is a plan the consent
	# memory does not cover. A workspace whose tiles all run the default shell
	# changes directory without a prompt — the accepted case.
	var tiles := _gather_tiles_from(ws.tm)
	if _tiles_untrusted_without_consent(tiles, clean):
		_ask_workspace_cwd_change(idx, clean, tiles)
		return
	_apply_workspace_cwd(idx, clean)

## The picker's trust half: the workspace's own tiles keep running, but the
## layout saved from them will start in `clean` on the next restore. The
## dialog names both so the new directory is the decision, not a side note.
func _ask_workspace_cwd_change(idx: int, clean: String, tiles: Array[Dictionary]):
	var dialog := AppDialog.confirm(self, "Workspace Trust")
	AppDialog.set_body(dialog, "Workspace '%s' would start these panes in a new directory the next time it is restored.\n\n%s\n\nChange the directory anyway?" % [str(_workspaces[idx].get("name", "")), _untrusted_details(tiles, clean)])
	dialog.ok_button_text = "Change Directory"
	dialog.cancel_button_text = "Cancel"
	dialog.confirmed.connect(func():
		_apply_workspace_cwd(idx, clean)
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	AppDialog.popup(dialog)

func _apply_workspace_cwd(idx: int, clean: String):
	if idx < 0 or idx >= _workspaces.size():
		return
	var ws: Dictionary = _workspaces[idx]
	if str(ws.get("cwd", "")) == clean:
		return
	ws["cwd"] = clean
	_update_workspace_ui()
	_save_workspaces_to_store()
	if clean == "":
		ToastManager.info("Workspace '%s' uses the default directory" % ws.name)
	else:
		ToastManager.info("Workspace '%s' starts new terminals in %s" % [ws.name, clean])

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
	# Zero workspaces is a saved state too: the next launch restores the guide.
	WorkspaceStore.save(_active, _all_layouts())

func _all_layouts() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for ws in _workspaces:
		out.append({
			"name": ws.name,
			"cwd": str(ws.get("cwd", "")),
			"layout": _gather_tiles_from(ws.tm),
			# The unit the geometry was written in, so a layout saved by an
			# older build (a coarser grid) still restores to the same shares.
			"grid_unit": PaneTypes.GRID,
		})
	return out

# ── Workspace (tab set) lifecycle ─────────────────────────────────────

func _init_workspaces():
	_teardown_workspaces()
	var store = WorkspaceStore.load()
	var wss: Array = store.get("workspaces", [])
	# No store and no legacy layout is a real state: a first run has no
	# workspace and no pane, and the first pane the user creates makes the
	# "Default" workspace. Only the legacy import synthesizes a workspace,
	# because it is migrating a layout the user actually saved - and only a
	# missing store migrates. An empty `wss` is also the saved "closed every
	# workspace" state; importing there resurrected the old layout on every
	# launch after a close-all.
	if wss.is_empty() and not WorkspaceStore.has_store():
		var legacy = WorkspaceStore.import_legacy_layout()
		if not legacy.is_empty():
			wss = [{"name": "Workspace 1", "layout": legacy}]
	var entries: Array[Dictionary] = []
	for entry in wss:
		if not (entry is Dictionary):
			continue
		entries.append({
			"name": WorkspaceStore.sanitize_name(str(entry.get("name", ""))),
			"cwd": WorkspaceStore.sanitize_cwd(str(entry.get("cwd", ""))),
			# Already sanitized by `WorkspaceStore.load`; the legacy-import
			# branch's synthesized entry has no field and stays unknown.
			"grid_unit": int(entry.get("grid_unit", 0)),
			"layout": _tiles_from(entry.get("layout", [])),
		})
	var active: int = clampi(int(store.get("active", 0)), 0, maxi(entries.size() - 1, 0))

	# Workspace trust: warn if any saved shell differs from the configured
	# default. Cancel keeps the layout but swaps untrusted shells out —
	# every workspace is rebuilt with the default shell instead. The consent
	# memory applies first: a tile whose exact spawn plan an approval covers
	# does not count, so a workspace saved from an approved profile restores
	# without re-asking.
	var untrusted: Array = []
	for i in entries.size():
		if _tiles_untrusted_without_consent(
			_tiles_from(entries[i].get("layout", [])), _spawn_cwd(entries[i])):
			untrusted.append(i)
	if not untrusted.is_empty():
		_show_multi_trust_dialog(entries, active, untrusted)
		return
	_build_workspaces(entries, active)

func _teardown_workspaces():
	for ws in _workspaces:
		ws.tm.reset()
		if ws.grid != _home_grid:
			ws.grid.queue_free()
	_workspaces.clear()
	# The home pair is the empty host. Resetting it here clears a workspace 0
	# from an earlier restore and removes the window where `_tm`/`_grid` could
	# point at a just-freed grid while the trust dialog is open.
	_home_tm.reset()
	_tm = _home_tm
	_grid = _home_grid
	_home_grid.visible = false
	_home_grid.process_mode = Node.PROCESS_MODE_DISABLED
	_apply_layout()

func _build_workspaces(entries: Array[Dictionary], active: int):
	for i in entries.size():
		var ws: Dictionary
		var ws_cwd := str(entries[i].get("cwd", ""))
		if i == 0:
			ws = {"name": entries[i].get("name", "Workspace 1"),
				"grid": _home_grid, "tm": _home_tm, "profile": "", "cwd": ws_cwd}
		else:
			ws = _new_workspace_container(str(entries[i].get("name", "")), ws_cwd)
		_workspaces.append(ws)
		var layout: Array = entries[i].get("layout", [])
		layout = TerminalManager.scale_layout(layout, int(entries[i].get("grid_unit", 0)))
		_restore_into(ws, _tiles_from(layout))
	_active = -1 if _workspaces.is_empty() \
		else clampi(active, 0, _workspaces.size() - 1)
	_apply_active_workspace_view()

func _restore_into(ws: Dictionary, tiles: Array[Dictionary]):
	var tm: TerminalManager = ws.tm
	tm.reset()
	# Sanitize the whole set first: an id collision is a property of the set
	# (and of the panes already live in other workspaces), and a companion may
	# reference a terminal that appears later in the list. Resolving both
	# before a body exists is what keeps the companion on its own terminal —
	# renaming at attach time would leave it pointed at the other instance.
	var plans: Array[Dictionary] = []
	for td in tiles:
		if not (td is Dictionary): continue
		var st = PaneTypes.sanitize_tile(td, PaneTypes.GRID)
		if st.is_empty(): continue
		plans.append({"tile": st, "legacy_shell": td.get("shell", "")})
	_resolve_tile_ids(plans)
	# The window's ceiling, applied where a file's tile count is spent: this
	# workspace's own panes were just reset, so the room is what the other
	# workspaces leave. A layout or profile with more tiles than that restores
	# the ones that fit and names the rest rather than starting a process per
	# tile until the machine gives out.
	var room := _live_pane_room()
	var restored := 0
	var skipped_by_limit := 0
	var dropped_env: Array[String] = []
	var dropped_settings: Array[String] = []
	for plan_idx in plans.size():
		if restored >= room:
			skipped_by_limit = plans.size() - plan_idx
			break
		var plan: Dictionary = plans[plan_idx]
		var st: Dictionary = plan["tile"]
		var settings: Dictionary = st["settings"]
		var type_name: String = st["type_name"]

		# A file's settings went through the pane type's closed table; whatever
		# it refused is named here once, so a typo or a crafted layout is
		# visible instead of silently changing the pane.
		for key in st.get("dropped", PackedStringArray()):
			var label: String = str(settings.get("pane_name", type_name))
			dropped_settings.append("%s: %s" % [label, PaneTypes._trust_text(str(key))])

		# A file must not carry env. Legacy tiles may have one; it is dropped
		# here — named in the notice, never adopted into the pane-env store,
		# because adopting would launder a hostile file's payload into the
		# trusted map. The pane's own env comes from PaneEnvStore at spawn.
		var file_env := str(settings.get("shell_env", "")).strip_edges()
		if file_env != "":
			settings.erase("shell_env")
			var label: String = str(settings.get("pane_name", type_name))
			dropped_env.append("%s: %s" % [label, PaneTypes._trust_text(file_env)])

		var body = tm.create_body(type_name)
		if body == null: continue
		body.apply_settings(settings)

		# For terminals: apply global defaults, then the per-tile command.
		# "command" carries a tool override (e.g. "herdr", "lazygit", "nvim");
		# "shell" is the legacy shell-binary key.  Priority: command > shell > default.
		# Both run through sanitize_shell — profile data is untrusted.
		if type_name == "terminal":
			var raw = settings.get("command", settings.get("shell", plan["legacy_shell"]))
			var sh: String = PaneTypes.sanitize_shell(raw, SettingsManager.cfg_shell_command)
			SettingsManager.apply_to_terminal(body)
			body.shell_command = sh
			if body is TerminalPane:
				# The workspace owns the directory; a tile cannot carry one.
				body.workspace_cwd = str(ws.get("cwd", ""))

		var title = PaneTypes.ALL.get(type_name, {}).get("name", type_name)
		var w = tm._build_wrapper_body(body, title)

		_attach_pane_into(ws, w, body)
		tm.tiles.append({wrapper = w, col = st["col"], row = st["row"],
			cspan = st["cspan"], rspan = st["rspan"]})
		restored += 1
	# A workspace's saved layout is the whole state: an empty one stays empty
	# and `_apply_layout` shows the guide. There is no first-run seed.
	tm._sync_edge_strips()

	if skipped_by_limit > 0:
		ToastManager.warn(
			"Restored %d of %d panes. %s"
			% [restored, plans.size(), _pane_ceiling_refusal()], 8.0)

	if not dropped_env.is_empty():
		var shown := dropped_env.slice(0, 3)
		var shown_ps := PackedStringArray()
		for s in shown:
			shown_ps.append(s)
		var more := dropped_env.size() - shown.size()
		var tail := ""
		if more > 0:
			tail = " (+%d more pane%s)" % [more, "s" if more > 1 else ""]
		ToastManager.warn(
			"Saved pane environment was dropped%s: %s. Files cannot supply environment — set it again in Pane Settings → Environment."
			% [tail, ", ".join(shown_ps)], 8.0)

	if not dropped_settings.is_empty():
		var shown_settings := dropped_settings.slice(0, 3)
		var shown_ps := PackedStringArray()
		for s in shown_settings:
			shown_ps.append(s)
		var more_settings := dropped_settings.size() - shown_settings.size()
		var tail_settings := ""
		if more_settings > 0:
			tail_settings = " (+%d more)" % more_settings
		ToastManager.warn(
			"Unsupported pane setting%s ignored in the saved layout%s: %s. A layout may only set the settings a pane saves; change the rest in Pane Settings."
			% ["" if dropped_settings.size() == 1 else "s", tail_settings, ", ".join(shown_ps)], 8.0)

func _tiles_from(raw: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for td in raw:
		if td is Dictionary:
			out.append(td)
	return out

## True when a saved tile would spawn something other than this user's current
## defaults. The program and its arguments both change what runs, so both are
## the trust decision — checking only `shell` (the legacy key) let a tile ship
## `command` or `shell_args: ["-c", "…"]` that the dialog never saw. Env is not
## a file decision: restore strips `shell_env` before it can reach a spawn.
func _tile_spawns_untrusted(td: Dictionary) -> bool:
	return PaneTypes.tile_spawns_untrusted(
		td, SettingsManager.cfg_shell_command)

func _tiles_untrusted(tiles: Array[Dictionary]) -> bool:
	for td in tiles:
		if _tile_spawns_untrusted(td):
			return true
	return false

## The directory a spawn in `ws` actually starts in, as the trust key names
## it: the workspace's sanitized directory when it is usable, otherwise ""
## (the PTY's inherited directory — what the backend itself falls back to for
## an unusable path, so a relative or stale store value cannot alias an
## approval for a directory the spawn never used).
func _spawn_cwd(ws: Dictionary) -> String:
	var cwd := WorkspaceStore.sanitize_cwd(str(ws.get("cwd", "")))
	if cwd == "" or not DirAccess.dir_exists_absolute(cwd):
		return ""
	return cwd

## The restore gate with the consent memory applied: an untrusted tile whose
## exact spawn plan (program, argv, and the workspace directory) an approval
## covers no longer counts. Anything not covered keeps today's behavior.
func _tiles_untrusted_without_consent(tiles: Array[Dictionary], cwd: String) -> bool:
	return not _plans_covered(
		tiles, TrustedStore.approved_plan_keys(GptyTerminal.get_app_version()), cwd)

## True when every untrusted tile's spawn plan in `cwd` is in `approved` — an
## Array of plan keys or a key->true dictionary (the two shapes the store
## answers in). A trusted tile needs no record; a tile whose untrusted spawn
## yields no key can never be covered, so it keeps asking.
func _plans_covered(tiles, approved, cwd: String) -> bool:
	for td in tiles:
		if not (td is Dictionary) or not _tile_spawns_untrusted(td):
			continue
		var key := PaneTypes.tile_plan_key(td, cwd)
		if key == "" or not _plan_approved(approved, key):
			return false
	return true

static func _plan_approved(approved, key: String) -> bool:
	if approved is Dictionary or approved is Array:
		return approved.has(key)
	return false

## Consent check for profile activation (and the IPC layoutLoad gate).
##
## Trust comes from `_origin` — the stamp `ProfileManager.get_all_profiles`
## puts on an entry — and never from fields inside the profile: a user file
## cannot claim `plugin_id` (the loader strips it), and an unstamped dict is
## user content. Each origin binds the approval to the content it covers:
##
## - plugin: the plugin id + revision the install review approved, AND every
##   untrusted tile's plan that review listed. A different revision re-prompts,
##   and so does different content under the same revision. The record stays
##   keyed on program + argv, without a directory: the review runs before any
##   workspace is chosen, and a plugin is arbitrary code either way.
## - user: every untrusted tile's plan covered by an approval recorded for a
##   pre-seed builtin at this directory — a workspace saved from one restores
##   the same way. Nothing is ever recorded for a user profile, so it asks
##   again.
func _profile_consented(profile: Dictionary) -> bool:
	var tiles = profile.get("tiles", [])
	var cwd := _spawn_cwd(_active_workspace())
	match str(profile.get("_origin", ProfileManager.ORIGIN_USER)):
		ProfileManager.ORIGIN_PLUGIN:
			var plugin_id := str(profile.get("plugin_id", ""))
			var revision := str(profile.get("revision", ""))
			return (
				TrustedStore.is_plugin_approved(plugin_id, revision)
				and _plans_covered(tiles, TrustedStore.plugin_plans(plugin_id, revision), "")
			)
	return _plans_covered(
		tiles, TrustedStore.approved_plan_keys(GptyTerminal.get_app_version()), cwd)

## The trust dialog's consent is remembered only for a plugin pinned at an
## approved revision. A plugin profile whose tiles changed under that revision
## adds the plans the dialog just showed to the record (program + argv only:
## the install review approved those before any workspace directory existed) —
## the revision itself is only ever approved by the install review, which
## shows the whole manifest. User-authored profiles never record consent, so
## approving one does not make the next activation silent.
func _remember_profile_consent(profile: Dictionary, tiles: Array):
	match str(profile.get("_origin", ProfileManager.ORIGIN_USER)):
		ProfileManager.ORIGIN_PLUGIN:
			var plugin_id := str(profile.get("plugin_id", ""))
			var revision := str(profile.get("revision", ""))
			if not TrustedStore.is_plugin_approved(plugin_id, revision):
				return
			TrustedStore.approve_plugin(
				plugin_id, revision,
				TrustedStore.plugin_plans(plugin_id, revision)
					+ _untrusted_plan_keys(tiles, ""))

## The plan keys the trust dialog just showed for `tiles` in `cwd`: only the
## tiles that needed the prompt, so a mostly-default layout cannot fill the
## store's plan cap with keys no gate consults.
func _untrusted_plan_keys(tiles, cwd: String) -> Array:
	var keys: Array = []
	for td in tiles:
		if not (td is Dictionary) or not _tile_spawns_untrusted(td):
			continue
		var key := PaneTypes.tile_plan_key(td, cwd)
		if key != "" and not keys.has(key):
			keys.append(key)
	return keys

## What the untrusted tiles in `tiles` would run, for the trust dialog. `cwd`
## is the directory the spawn will start in; it is named first because it is
## part of the plan the user is approving. Capped in PaneTypes — the content
## is file data, not something we render raw.
func _untrusted_details(tiles: Array[Dictionary], cwd := "") -> String:
	var lines: Array[String] = []
	if cwd != "":
		lines.append("directory: " + PaneTypes._trust_text(cwd))
	for td in tiles:
		var plan := PaneTypes.untrusted_plan(
			td, SettingsManager.cfg_shell_command)
		if plan.is_empty():
			continue
		var settings = td.get("settings", {})
		var kind := "terminal" if not (settings is Dictionary) else str(settings.get("type", "terminal"))
		lines.append("%s pane:" % kind)
		for line in plan:
			lines.append("  " + line)
		if lines.size() >= PaneTypes.TRUST_MAX_DETAIL_LINES:
			lines.resize(PaneTypes.TRUST_MAX_DETAIL_LINES)
			lines.append("  … more panes not shown")
			break
	return "\n".join(lines)

func _show_multi_trust_dialog(entries: Array[Dictionary], active: int, untrusted: Array):
	var dialog := AppDialog.confirm(self, "Workspace Trust")
	# Grouped per workspace: the directory is workspace-scoped, so flattening
	# the tiles would show one workspace's panes under another's directory (or
	# no directory at all, which is exactly what this dialog has to name).
	var lines: Array[String] = []
	for i in untrusted:
		var header := "Workspace '%s'" % str(entries[i].get("name", "Workspace"))
		lines.append(header + ":")
		var details := _untrusted_details(
			_tiles_from(entries[i].get("layout", [])), _spawn_cwd(entries[i]))
		for line in details.split("\n"):
			if line == "":
				continue
			if lines.size() >= PaneTypes.TRUST_MAX_DETAIL_LINES:
				lines.append("  … more panes not shown")
				break
			lines.append("  " + line)
		if lines.size() >= PaneTypes.TRUST_MAX_DETAIL_LINES:
			break
	var details := "\n".join(lines)
	AppDialog.set_body(dialog, "This layout contains %d workspace(s) whose panes start a different program or pass extra arguments than your current default shell (%s).\n\n%s\n\nRestore them anyway?" % [untrusted.size(), SettingsManager.cfg_shell_command, details])
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
	AppDialog.popup(dialog)

func _restore():
	# Palette "load": reload the saved workspace set from disk. Every pane in
	# every workspace is about to be destroyed, so all of them are asked.
	_ask_close_then(
		_all_pane_bodies(), _init_workspaces, Callable(), true,
		"Restoring the saved workspaces")

# ═══════════════════════════════════════════════════════════════════════
# Overlay keyboard ownership
# ═══════════════════════════════════════════════════════════════════════

## Escape from a pane-chrome button hands the keyboard back to the pane. Chrome
## is a toolbar of focusable buttons (`TerminalManager._wire_chrome_keyboard`);
## a focused button has no typing and no other Escape meaning, so the key is
## claimed here, at the raw stage, rather than in `_gui_input` (delivered to the
## focused control only). A terminal's own Escape never gets here: its
## `_handle_keyboard` accepts the event first.
func _escape_pane_chrome() -> bool:
	var owner := get_viewport().gui_get_focus_owner()
	if owner == null:
		return false
	var ws := _active_workspace()
	if ws.is_empty():
		return false
	for t in ws.tm.tiles:
		var bar: Control = t.wrapper.get_node_or_null("BodyVBox/TitleBar")
		if bar == null or not bar.is_ancestor_of(owner):
			continue
		ws.tm._return_focus_to_body(ws.tm._find_body(t.wrapper))
		return true
	return false

## Move the keyboard from the active pane into its title bar. A focused
## terminal consumes Tab for its child, so this is the only way a keyboard user
## enters pane chrome; Escape in the bar returns to the pane, and the bar's
## buttons ring among themselves (`TerminalManager._wire_chrome_keyboard`). An
## open overlay keeps the keyboard: the shortcut does nothing while one is up.
func _focus_active_pane_chrome() -> void:
	if _keyboard_overlay() != null:
		return
	var ws := _active_workspace()
	if ws.is_empty():
		return
	var body: Control = ws.tm.last_body
	if body != null and is_instance_valid(body):
		ws.tm.focus_title_bar(body)

## Escape from the window's own title bar hands the keyboard back to the active
## pane - the same one-level-out step pane chrome takes. `_escape_pane_chrome`
## never matches it: the bar is outside every tile.
func _escape_window_chrome() -> bool:
	var owner := get_viewport().gui_get_focus_owner()
	if owner == null or _chrome.titlebar == null or not _chrome.titlebar.is_ancestor_of(owner):
		return false
	var ws := _active_workspace()
	if ws.is_empty():
		owner.release_focus()
	else:
		ws.tm._return_focus_to_body(ws.tm.last_body)
	return true

## Enter the window's own title bar from the keyboard. The bar is not a pane's
## chrome, so it has its own entry: the same overlay guard, then WindowChrome's
## own predicate for "the bar is on screen and has a stop".
func _focus_window_chrome() -> void:
	if _keyboard_overlay() != null:
		return
	_chrome.focus_controls()

## Move the keyboard from a wiki note's buffer into that note's toolbar — the
## note view's counterpart to `Ctrl+Shift+E`. The toolbar is one ring
## (`WikiPane._wire_note_toolbar`), but a focused `CodeEdit` keeps Tab for
## indentation, so the chord is the way in; Escape in the toolbar returns to the
## buffer, and only the buffer's own Escape leaves the note.
##
## The pane is the one that owns the focus owner: the chord is typed from inside
## the note, and `last_body` can still name the pane the user last clicked —
## measured: a wiki pane opened from the list kept `last_body` on the startup
## terminal, so a `last_body`-only rule did nothing from the very buffer the
## chord exists for. The active pane is the fallback, so the chord has a target
## when nothing in the pane holds focus. Inert when that pane is not a wiki pane
## in a note, and while an overlay owns the keyboard.
func _focus_note_toolbar() -> void:
	if _keyboard_overlay() != null:
		return
	var wiki: WikiPane = null
	var owner := get_viewport().gui_get_focus_owner()
	if owner != null:
		var focused := _body_of_focus_owner(owner)
		if focused is WikiPane:
			wiki = focused as WikiPane
	if wiki == null:
		var ws := _active_workspace()
		if ws.is_empty():
			return
		var body: Control = ws.tm.last_body
		if body is WikiPane:
			wiki = body as WikiPane
	if wiki != null and is_instance_valid(wiki):
		wiki.focus_note_toolbar()

## Enter the active pane's own action bar (a code viewer's Reload and view
## toggle, a CLI view's Restart and Stop). The pane resolution is the note
## toolbar's: the pane that owns the focus owner, else the workspace's last
## active pane, because the chord may be typed while a read-only pane is active
## without holding a focus owner inside it.
func _focus_pane_toolbar() -> void:
	if _keyboard_overlay() != null:
		return
	var body: Control = null
	var owner := get_viewport().gui_get_focus_owner()
	if owner != null:
		body = _body_of_focus_owner(owner)
	if body == null:
		var ws := _active_workspace()
		if not ws.is_empty():
			body = ws.tm.last_body
	if body is PaneBody and is_instance_valid(body):
		(body as PaneBody).focus_toolbar()

## Escape inside a pane's own action bar returns to the pane's content - the
## same one-level-out step pane chrome takes, and the branch the Wiki pane's
## note toolbar shares instead of its own copy.
func _escape_pane_toolbar() -> bool:
	var owner := get_viewport().gui_get_focus_owner()
	if owner == null:
		return false
	var body := _body_of_focus_owner(owner)
	if body == null or not body is PaneBody:
		return false
	if not (body as PaneBody).toolbar_has_focus(owner):
		return false
	(body as PaneBody).leave_toolbar()
	return true

## The overlay that owns the keyboard while it is visible, topmost first.
## Opening Settings closes Pane Settings, the concept editor opens over
## Settings and the palette can open over either, so this order is the stacking
## order (each opener moves its overlay to the last child).
func _keyboard_overlay() -> OverlayPanel:
	var candidates: Array[Node] = [_palette, _concept_graph, _settings_panel]
	if _tm != null:
		candidates.append(_tm._pane_settings_panel)
	for candidate in candidates:
		if candidate is OverlayPanel and (candidate as OverlayPanel).visible:
			return candidate
	return null

## The overlay hid while it still owned the keyboard, and Godot drops focus for
## a hidden control, so put the keyboard back: to the overlay underneath when
## there is one (the concept editor opens over Settings, and that panel must
## keep the keyboard it had), otherwise to the workspace's active pane. A
## sidebar button that happened to open the overlay is not a restore target —
## Escape means the user is done with overlays and a focused button would
## swallow every letter typed next. A close caused by a click elsewhere never
## reaches here, so a click is never overridden.
func _on_overlay_keyboard_released(overlay: OverlayPanel) -> void:
	var target: Control = overlay.return_focus
	overlay.return_focus = null
	var below := _keyboard_overlay()
	if below != null:
		# Back to the overlay underneath, never to a pane: it is still open and
		# owns the keyboard. Its remembered control is the ideal target; when
		# that control is gone, or the closed overlay opened with no focus owner
		# at all, the overlay takes a control again rather than leaving the
		# terminal behind both with the keyboard while an overlay is visible.
		if target != null and is_instance_valid(target) \
				and target.is_visible_in_tree() and below.is_ancestor_of(target):
			target.grab_focus()
		else:
			below.grab_keyboard()
		return
	var ws := _active_workspace()
	if ws.is_empty():
		return
	var body: Control = ws.tm.last_body
	if body != null and is_instance_valid(body) and body.is_visible_in_tree():
		activate_pane(body)

func _input(event):
	# Raw input — fires before GUI consumption, which is required: pane
	# bodies contain RichTextLabels/ScrollContainers that consume clicks,
	# and _unhandled_input would never see them. The workspace fills the
	# window, so the event's viewport position maps 1:1 to canvas space.
	#
	# Escape belongs to the open overlay, and this is the only stage that can
	# deliver it: a focused terminal consumes every key in `_gui_input` (Escape
	# becomes the raw ESC byte its child expects), so no overlay
	# `_unhandled_input` handler ever runs while a terminal holds the keyboard.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		var overlay := _keyboard_overlay()
		if overlay != null:
			overlay.close()
			get_viewport().set_input_as_handled()
			return
		if _escape_pane_chrome():
			get_viewport().set_input_as_handled()
			return
		if _escape_window_chrome():
			get_viewport().set_input_as_handled()
			return
		if _escape_pane_toolbar():
			get_viewport().set_input_as_handled()
			return
	# An in-flight pane-edge drag owns the mouse the same way: it starts on a
	# strip at the pane's border, so the very next motion is already over the
	# pane body (which would read it as a text selection). Driving the drag
	# from here keeps it alive across the whole window.
	if _tm != null and _tm.drag_active() and _tm.drive_edge_drag(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_activate_pane_under_mouse(event.position)

## Make `body` the active pane: the workspace that owns it records it (sidebar
## accent, status bar, keyboard routing), and only a pane that can hold
## keyboard focus receives focus — a read-only pane must not keep the keys the
## user just left on a terminal, and a pane that cannot take focus (or is not
## in the tree yet) must not raise an engine error. Shared by the three ways a
## pane is activated: a click, a sidebar row, and an IPC focus request.
func activate_pane(body: Control) -> void:
	if body == null:
		return
	_record_active_pane(body)
	# An open overlay owns the keyboard: a shortcut-spawned pane, an IPC
	# `focusPane` or a click behind it may change which pane is active, but
	# focus must not move to a terminal while the overlay is still there (the
	# overlay closes with Escape and only then hands the keyboard back).
	if _keyboard_overlay() != null:
		return
	if body is TerminalPane:
		body._take_focus()
	else:
		var owner := get_viewport().gui_get_focus_owner()
		if owner:
			owner.release_focus()

## Uniform click-to-activate: any left click inside a pane (body, titlebar
## background, or an inner widget) makes that pane the active one. The
## sidebar/status bar are not tile wrappers, so their clicks are no-ops.
## The focus rule itself lives in `activate_pane`.
func _activate_pane_under_mouse(mouse: Vector2):
	var ws := _active_workspace()
	if ws.is_empty():
		return
	# An open overlay owns the click as well as the keyboard: the raw stage runs
	# before GUI picking, so without this a click on the panel (or anywhere over
	# a tile) would re-focus the pane underneath and typing would reach the
	# shell while the overlay is still open.
	if _keyboard_overlay() != null:
		return
	for t in ws.tm.tiles:
		var w: Control = t.wrapper
		if not w.get_global_rect().has_point(mouse):
			continue
		var body = ws.tm._find_body(w)
		if body == null:
			continue
		activate_pane(body)
		return

func _toggle_palette():
	if _palette == null:
		_palette = CommandPalette.new()
		_palette.name = "Palette"
		_palette.z_index = 100
		add_child(_palette)
		_palette.visible = false  # start hidden — the first toggle must OPEN it
		# Full rect: the palette centres its own card, so the workspace never
		# positions it (a centre preset here ran while the size was zero, which
		# put the card's top-left on the workspace centre).
		_palette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_palette.command_chosen.connect(_execute_command)
		_palette.keyboard_released.connect(_on_overlay_keyboard_released.bind(_palette))
	if _palette.visible:
		_palette.close()
		return
	# Input picking uses reverse tree order (z_index is rendering-only);
	# keep the palette topmost over workspaces added after first use.
	move_child(_palette, -1)
	# The user's own commands, and whether they have anywhere to go, are read
	# here and not by the palette: `CommandPalette` reaches no store.
	_palette.set_saved_commands(SavedCommandStore.all(), _saved_command_refusal())
	_palette.open()

func _execute_command(cmd: String):
	if cmd.begins_with(PaletteModel.SAVED_PREFIX):
		_run_saved_command(cmd.substr(PaletteModel.SAVED_PREFIX.length()))
		return
	if cmd.begins_with("new "):
		var type_label = cmd.substr(4).strip_edges()
		for key in PaneTypes.ALL:
			if PaneTypes.ALL[key]["name"].to_lower() == type_label:
				_spawn_pane(key)
				return
		return
	match cmd:
		"close active": _kill_last()
		"settings": _toggle_settings()
		"shortcuts": _open_shortcuts_settings()
		"save command": _open_commands_settings()
		"close all": _reset()
		"save": _save()
		"load": _restore()

## A saved command (`user://commands.json`) is typed into the ACTIVE terminal
## pane and nowhere else: the text is the user's own words for the shell they
## are looking at, so it is never routed to another pane and never expanded.
## The palette asks `_saved_command_refusal` before it opens and the dispatcher
## asks again before it writes — one refusal, two readers.
func _run_saved_command(name: String) -> void:
	var entry := SavedCommandStore.find(name)
	if entry.is_empty():
		ToastManager.warn("The saved command '%s' no longer exists" % name)
		return
	var body := _saved_command_target()
	if body == null:
		ToastManager.warn(_saved_command_refusal())
		return
	_deliver_saved_command(body, entry)

## `run` writes a line (Enter included); an insert writes the bytes only, so
## the command is at the prompt, unexecuted, for the user to read and edit.
func _deliver_saved_command(body: TerminalPane, entry: Dictionary) -> void:
	var text := str(entry.get("command", ""))
	if bool(entry.get("run", false)):
		body._send_line_to_term(text)
	else:
		body._send_to_term(text)
	# The command is about to appear at the prompt: a scrolled-back pane would
	# hide the only feedback an insert gets.
	body._snap_to_bottom()

## The pane a saved command may be written to, or null when there is none.
func _saved_command_target() -> TerminalPane:
	if _saved_command_refusal() != "":
		return null
	return _tm.last_body as TerminalPane

## Why no pane can take a saved command right now, or "".
func _saved_command_refusal() -> String:
	var body: Control = _tm.last_body
	if body == null or not is_instance_valid(body):
		return SAVED_NO_PANE
	if not (body is TerminalPane):
		return SAVED_NOT_TERMINAL
	if not body.is_visible_in_tree():
		return SAVED_MINIMIZED
	return ""

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
		# Same uniform semantics as clicking the pane itself (see
		# `activate_pane`).
		activate_pane(body)
	)
	_sidebar.request_pane_menu.connect(func(body: Control, btn: Button): _on_pane_menu(body, btn))
	_sidebar.request_pane_settings.connect(func(body: Control): _tm._open_pane_settings(body))
	_sidebar.toggled.connect(func(): _on_sidebar_toggled())
	_sidebar.request_profile.connect(_activate_profile)
	_sidebar.request_profile_in_new_workspace.connect(_open_profile_in_new_workspace)
	_sidebar.request_profile_rename.connect(_rename_profile)
	_sidebar.request_window_mode.connect(_chrome.on_window_mode_selected)
	_sidebar.request_search.connect(_open_active_search)
	_sidebar.request_workspace_switch.connect(_switch_workspace)
	_sidebar.request_workspace_add.connect(_add_workspace)
	_sidebar.request_workspace_close.connect(_close_workspace)
	_sidebar.request_workspaces_close_all.connect(_close_all_workspaces)
	_sidebar.request_workspace_menu.connect(func(idx: int, btn: Button): _on_workspace_menu(idx, btn))
	_sidebar.request_workspace_rename.connect(_rename_workspace)
	_sidebar.request_save_profile.connect(_save_current_as_profile)
	_sidebar.request_delete_profile.connect(_delete_profile)
	_sidebar.request_profile_uninstall.connect(_uninstall_profile_plugin)
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
# pluginInstall reviews waiting on the dialog: id -> summary params
var _pending_plugin_reviews: Dictionary = {}
# Accepted installs that promised a same-name replacement: plugin id -> raw
# profile names the review named. Applied only after the plugin's record is
# visible, so a failed install deletes nothing.
var _pending_profile_replacements: Dictionary = {}

## How long a pane answer waits for its pane's child before it answers an
## error. The child starts within a frame or two of the handler returning, so
## this is a guard against a wedged frame, not a latency anyone should see —
## and the Rust edge's own fallback (`GDS_RESPONSE_TIMEOUT`, 5 s) started
## earlier, so a request that waits this long has already been answered.
const PANE_START_ANSWER_TIMEOUT_MS := 5000
## Pane answers held until their pane's child starts, keyed by the body's
## instance id: {id: int, pane_id: String, body: Control, answer: Dictionary,
## deadline_ms: int}. `newPane`/`paneRun` answer a `pane_id` before that pane's
## child exists, so the answer is only true once `child_started` (or an error,
## via `child_start_failed`) says what happened — `_hold_pane_answer`.
var _pending_pane_starts: Dictionary = {}

func _process(_delta: float):
	# Concept event polling — must run even before sidebar is ready
	_poll_agent_events()
	_prime_new_pane_observers()
	_poll_concept_events()
	_poll_ipc_requests()
	_poll_pending_waits()
	_poll_pending_pane_starts()
	if _sidebar == null: return
	# FPS counter update (throttled to ~4 Hz)
	if Engine.get_process_frames() % 15 == 0 and _status_bar:
		_status_bar.set_fps(Engine.get_frames_per_second())
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
	_route_agent_events(events)

## Route one drained batch to the panes that observe the emitting terminal.
##
## The source is resolved by FFI session id — a pane's `attachment_id` is
## reassigned when it collides, the session id never is — and the envelope goes
## only to receivers in that terminal's own workspace. A profile activated in
## two workspaces names the same logical companion in both, and only one
## instance can keep the id, so the unscoped fan-out showed one workspace's
## stream inside the other. Hidden workspaces still hear their own terminals
## (their PTYs stay alive). Split from the drain so GUT can feed synthetic
## envelopes without an agent extension behind them.
func _route_agent_events(events: Array):
	# One pass per drain: session → source (with its workspace index), and the
	# receivers grouped by workspace, so each event no longer re-scans every
	# tile twice (O(E×T²) → O(T + E×R)).
	var source_by_session := {}
	var receivers_by_ws: Array = []
	for i in _workspaces.size():
		var ws: Dictionary = _workspaces[i]
		var receivers: Array[Control] = []
		for t in ws.tm.tiles:
			var body = ws.tm._find_body(t.wrapper)
			if body == null:
				continue
			if body.has_method("receive_agent_event"):
				receivers.append(body)
			if body is TerminalPane and body.get("_terminal") != null:
				var session_id := str(body._terminal.get_terminal_session_id())
				if session_id != "":
					source_by_session[session_id] = {"body": body, "workspace": i}
		receivers_by_ws.append(receivers)
	for envelope in events:
		if not (envelope is Dictionary):
			continue
		var src = source_by_session.get(str(envelope.get("terminal_session_id", "")), null)
		if src == null:
			continue
		var source: Control = src["body"]
		var event = envelope.get("event", {})
		# Tier 1 (authoritative): capability-authenticated events set the
		# terminal's agent state before routing. Display state only.
		var state: String = Workspace.agent_state_for_event(event)
		if state != "" and source.get("_terminal") != null:
			source._terminal.set_agent_state(state)
		var source_id: String = source.attachment_id if source.attachment_id != "" else source.pane_label
		var receivers: Array = receivers_by_ws[int(src["workspace"])]
		for receiver in receivers:
			receiver.receive_agent_event(envelope, source_id)

# ═══════════════════════════════════════════════════════════════════════
# Agent-state observation contract
# ═══════════════════════════════════════════════════════════════════════

## The workspace is the only dispatcher for the pane contract
## (`PaneBody.agent_state_source_id` / `on_agent_state_changed`): a terminal
## emits its tiered state change and every pane observing that terminal hears
## it, at most once per delivery. Panes are found through the `panes` group,
## not the tile lists, so hidden workspaces keep observing their own; the
## source is resolved inside the observer's own workspace, so a companion left
## pointing at another workspace's id observes nothing rather than that
## terminal. Display only — a Tier 2 state is spoofable and Tier 3 is a
## heuristic, so nothing here may feed a decision.

## What every observer was last told, by instance id: `[source_id, state]`.
## The source half keeps a pane re-pointed at another terminal (a settings
## edit) from counting as settled — it is primed again — and the state half is
## the delivery shadow that makes the entry prime and a same-frame change emit
## impossible to deliver twice (the dispatcher-side mirror of the terminal's
## own `_badge_state` rule). A pane entering the tree by ANY route — spawn,
## restore, swap, a future pane SDK — is primed on the next frame once it owns
## a tile in a workspace, instead of only on the tile-attach path, and a
## follower whose terminal has not appeared yet is retried until it does. The
## scan is O(panes); only new or re-pointed panes pay the workspace lookup.
var _agent_state_primed := {}

func _prime_new_pane_observers():
	for body in get_tree().get_nodes_in_group("panes"):
		if not (body is PaneBody):
			continue
		var key := body.get_instance_id()
		var source_id: String = body.agent_state_source_id()
		var record = _agent_state_primed.get(key)
		if record != null and str(record[0]) == source_id:
			continue  # already settled for this source
		if source_id == "":
			_agent_state_primed[key] = ["", ""]  # observes nothing, ever
			continue
		# Observation is workspace-scoped: the terminal must live in the
		# observer's own workspace. A pane not attached to a tile yet (mid-swap,
		# mid-restore) is retried next frame.
		var ws := _workspace_for_body(body)
		if ws.is_empty():
			continue
		var terminal := _terminal_for_agent_state(ws, source_id)
		if terminal == null or terminal._terminal == null:
			continue  # the source is not attached yet: try again next frame
		# The entry delivery is this scan's job and goes to *this* pane alone:
		# it used to broadcast to every observer of the source, re-telling
		# settled panes the state they already held whenever one pane attached.
		_agent_state_primed[key] = [source_id, ""]
		_tell_observer(body, source_id, terminal._terminal.get_agent_state())

func _terminal_for_agent_state(ws: Dictionary, source_id: String) -> Control:
	if source_id == "" or ws.is_empty():
		return null
	for t in ws.tm.tiles:
		var body = ws.tm._find_body(t.wrapper)
		if body is TerminalPane and body.attachment_id == source_id:
			return body
	return null

func _dispatch_agent_state(ws: Dictionary, source_id: String, state: String):
	if source_id == "" or ws.is_empty():
		return
	for t in ws.tm.tiles:
		var body = ws.tm._find_body(t.wrapper)
		if not (body is PaneBody) or body.agent_state_source_id() != source_id:
			continue
		# Only a pane the scan has already settled hears a change: delivering
		# to one it has not would make the scan's entry the duplicate instead
		# (the scan runs every frame, so an entry lags at most a frame).
		var record = _agent_state_primed.get(body.get_instance_id())
		if record == null or str(record[0]) != source_id:
			continue
		_tell_observer(body, source_id, state)

## One delivery to one observer, dropped when it already holds this value.
## Both paths — the scan's entry prime and a change emit — come through here,
## so the same state can never be delivered twice in a row; that is the same
## rule the terminal's own hook applies for itself through `_badge_state`.
func _tell_observer(body: PaneBody, source_id: String, state: String):
	var record = _agent_state_primed.get(body.get_instance_id())
	if record == null or str(record[0]) != source_id or str(record[1]) == state:
		return
	record[1] = state
	body.on_agent_state_changed(state)

## Map a generic-vocabulary event to the Tier 1 agent state it declares.
## `state.declared` carries the state in its own field — an explicit
## declaration from the pane's program (`gpty state`), which is how a program
## declares state on Windows, where ConPTY consumes the `gpty_state` OSC
## before the pane's parser can see it. Empty string = nothing declared.
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
		"state.declared":
			# The event socket already held the value to the declaration
			# vocabulary; the terminal re-checks it on the way in.
			return str(event.get("state", ""))
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
	_poll_orphaned_captures()

## Route captures whose source pane was torn down mid-capture (closed,
## swapped, or the layout reset). Rust finalizes those into the engine's
## orphan queue; there is no source terminal left to acknowledge or flush —
## its grid and raw-byte store went with the pane — so a missed route means
## only that the captured output is gone.
func _poll_orphaned_captures():
	var events = GptyTerminal.drain_orphaned_captures()
	if events.is_empty():
		return
	# Which workspace the capture came from is unknown. Offer the active one
	# first: a visible receiver is the likeliest home for it.
	var order: Array[int] = []
	if _active >= 0 and _active < _workspaces.size():
		order.append(_active)
	for i in _workspaces.size():
		if i != _active:
			order.append(i)
	var bodies: Array[Control] = []
	for i in order:
		var ws: Dictionary = _workspaces[i]
		for t in ws.tm.tiles:
			var body = ws.tm._find_body(t.wrapper)
			if body != null:
				bodies.append(body)
	for ev in events:
		if not (ev is Dictionary):
			continue
		if not ConceptRouter.route_orphaned_capture(bodies, ev):
			var target := str(ev.get("target_pane_type", ""))
			var pane_label := str(PaneTypes.ALL.get(target, {}).get("name", target))
			ToastManager.warn("No %s pane open for '%s' output (the source pane closed)" % [
				pane_label, ev.get("concept_name", "")])
		# `source` is empty: the pane that produced the capture no longer
		# exists, and the event schema keeps the same keys for subscribers.
		GptyTerminal.emit_event(JSON.stringify({
			"type": "concept",
			"name": str(ev.get("concept_name", "")),
			"source": "",
			"target": str(ev.get("target_pane_type", "")),
		}))

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
		# Notify-only concepts (`capture_mode: single_line`): the trigger fired,
		# nothing was captured and no pane received anything. Subscribers get the
		# match; the output stays in the terminal. Metadata only — the matched
		# line is deliberately not published.
		for notice in term.drain_concept_notices():
			if not (notice is Dictionary):
				continue
			GptyTerminal.emit_event(JSON.stringify({
				"type": "concept",
				"event": "matched",
				"mode": "single_line",
				"name": str(notice.get("concept_name", "")),
				"source": str(body.attachment_id),
			}))
# ═══════════════════════════════════════════════════════════════════════
# IPC bridge — polls Rust IPC requests from _process
# ═══════════════════════════════════════════════════════════════════════

func _poll_ipc_requests():
	if GptyTerminal.take_shutdown_request():
		# A refusal to start (another window holds the control socket) quits
		# too, but closing without a word reads as a crash — say why first.
		# The toast is in-window and needs no external process: `OS.alert`
		# blocks on zenity/kdialog and hangs a headless run (measured), so
		# headless quits at once and a desktop gets a moment to read the line.
		var failure := GptyTerminal.take_startup_failure()
		if failure != "":
			ToastManager.warn(failure)
			if DisplayServer.get_name() != "headless":
				await get_tree().create_timer(4.0).timeout
			# A refused instance never served a workspace, so there is no work
			# to ask about. The normal quit walk would raise a dialog nothing
			# can answer in a headless launch - and on Windows every live shell
			# is conservatively busy, so the refused second instance used to
			# hang instead of exiting.
			quit_action.call()
			return
		# A normal shutdown request still asks: it must not drop what a pane
		# holds (the same walk the window close uses).
		request_quit()
		return
	# GptyTerminal is a GodotClass — call static methods on the class
	var reqs = GptyTerminal.drain_ipc_requests()
	if reqs.is_empty():
		return
	for req in reqs:
		for answer in WorkspaceIpcHandlers.dispatch_request(self, req):
			var payload = answer["payload"]
			# A handler may already return its JSON as a string (`vaultRead`
			# does); everything else is serialized once, here.
			var text = payload if typeof(payload) == TYPE_STRING else JSON.stringify(payload)
			send_ipc_answer.call(int(answer["id"]), bool(answer["success"]), text)

# Poll registered paneWait requests each frame: respond on first regex match
# or deadline. Matching happens in Rust (standard regex crate) per pane.
func _poll_pending_waits():
	if _pending_waits.is_empty():
		return
	var now = Time.get_ticks_msec()
	var done: Array = []
	for wid in _pending_waits:
		var w = _pending_waits[wid]
		var wbody = _resolve_pane_target(str(w.get("attachment_id", ""))).get("body")
		if wbody == null or not (wbody is TerminalPane):
			send_ipc_answer.call(int(wid), false, JSON.stringify(_ipc_error("Pane gone")["error"]))
			done.append(wid)
			continue
		var line = str(wbody._terminal.check_lines(w["pattern"]))
		if line != "":
			send_ipc_answer.call(int(wid), true, JSON.stringify({"matched": true, "line": line}))
			done.append(wid)
		elif now >= w["deadline_ms"]:
			send_ipc_answer.call(int(wid), true, JSON.stringify({"matched": false, "timed_out": true}))
			done.append(wid)
	for wid in done:
		_pending_waits.erase(wid)

## Hold an answer that names a pane until that pane's child has started.
##
## A terminal starts its child from the first size its tile is laid out at,
## which happens after the IPC drain returns — so answering here would report a
## spawn that has not happened yet, and a spawn that then failed would have
## been reported as a success (the defect this exists for). Returns true when
## the answer was held, false when it can go out now: the target is not a
## terminal (nothing to wait for), it has already resolved its start, or its id
## names no pane at all — an answer is never swallowed.
func _hold_pane_answer(id: int, answer: Dictionary) -> bool:
	var pane_id := str(answer.get("pane_id", ""))
	var body = _resolve_pane_target(pane_id).get("body")
	if body == null or not (body is TerminalPane):
		return false
	if body.child_start_resolved():
		return false
	_pending_pane_starts[body.get_instance_id()] = {
		"id": id,
		"pane_id": pane_id,
		"body": body,
		"answer": answer,
		"deadline_ms": Time.get_ticks_msec() + PANE_START_ANSWER_TIMEOUT_MS,
	}
	return true

## Answer a held pane request: its document on success, or the flat
## `{code, message}` error object the Rust edge turns into the JSON-RPC error.
func _send_held_pane_answer(held: Dictionary, reason := "") -> void:
	if reason == "":
		send_ipc_answer.call(int(held["id"]), true, JSON.stringify(held["answer"]))
	else:
		send_ipc_answer.call(int(held["id"]), false, JSON.stringify(_ipc_error(reason)["error"]))

func _on_pane_child_started(body: Control) -> void:
	var held = _pending_pane_starts.get(body.get_instance_id())
	if held == null:
		return
	_pending_pane_starts.erase(body.get_instance_id())
	_send_held_pane_answer(held)

## The child refused to start: answer the caller with the reason, tell the
## user, and close the tile. A pane with no child can never run anything, so
## leaving it would hand the user an empty grid that looks like a hung shell.
func _on_pane_child_failed(body: Control, reason: String) -> void:
	var held = _pending_pane_starts.get(body.get_instance_id())
	if held != null:
		_pending_pane_starts.erase(body.get_instance_id())
		_send_held_pane_answer(held, reason)
	ToastManager.warn(reason)
	_kill_now(body)

## Deadline sweep: a pane that neither started nor failed (a pane closed in the
## frame before its first layout, a frame that never ran) must still answer its
## caller rather than leaving the request to the Rust edge's generic timeout.
func _poll_pending_pane_starts():
	if _pending_pane_starts.is_empty():
		return
	var now = Time.get_ticks_msec()
	var expired: Array = []
	for key in _pending_pane_starts:
		var held = _pending_pane_starts[key]
		var body = held["body"]
		if body != null and is_instance_valid(body) and now < int(held["deadline_ms"]):
			continue
		expired.append(key)
	for key in expired:
		var held = _pending_pane_starts[key]
		_pending_pane_starts.erase(key)
		_send_held_pane_answer(held, "Pane '%s' never started" % str(held["pane_id"]))

func _handle_ipc_method(method: String, params):
	return WorkspaceIpcHandlers.handle(self, method, params)

# ── Plugin install review (pluginInstall) ─────────────────────────────
#
# The CLI sends the validated manifest summary; a human approves here before
# anything installs (the same trust model as the Workspace Trust dialog, and
# the same deferred-response pattern as paneWait). The dialog text is built
# by PluginReviewText — a pure, unit-tested builder whose caps keep the
# untrusted manifest strings from shaping the dialog.

const PLUGIN_REVIEW_MAX_PENDING := 4

## The summary's profile names that already exist as user profiles. Only
## those get the replacement consent line; a plugin-owned name is not a
## replacement target (the user profile would take the bare name and the
## plugin would re-derive with a suffix).
func _profile_names_colliding(params: Dictionary) -> Array[String]:
	var names: Array[String] = []
	var profiles = params.get("profiles", [])
	if not (profiles is Array):
		return names
	for entry in profiles:
		if not (entry is Dictionary):
			continue
		var name := str(entry.get("name", ""))
		if name == "" or names.has(name):
			continue
		if ProfileManager.find_user_profile(name) >= 0:
			names.append(name)
	return names

## Ask the user to review a plugin install. The IPC response is deferred:
## the answer lands when the dialog closes, and the Rust-side fallback
## deadline for this method is minutes, not seconds.
##
## A review must not outlive the request that asked for it: `timeout_ms` is
## that request's *remaining* fallback deadline (Rust hands it over with the
## request), and when it passes the dialog closes itself and says so. Without
## that, a click on a dialog whose request had already died would answer a
## channel nobody is listening on (`respond_ipc` no-ops) while the user
## believed the install happened.
func _show_plugin_review(id: int, params: Dictionary, timeout_ms: int):
	if timeout_ms <= 0:
		# The request expired before this frame drained it, so there is no
		# channel left to answer: do not open a dialog for it.
		return
	if _pending_plugin_reviews.size() >= PLUGIN_REVIEW_MAX_PENDING:
		send_ipc_answer.call(id, false, JSON.stringify(_ipc_error("Too many pending plugin reviews")["error"]))
		return
	var replaces := _profile_names_colliding(params)
	var dialog := AppDialog.confirm(self, "Plugin Install Review")
	dialog.name = "PluginReviewDialog"
	AppDialog.set_body(dialog, PluginReviewText.build(params, replaces), AppDialog.REVIEW_BODY_SIZE)
	dialog.ok_button_text = "Install"
	dialog.cancel_button_text = "Decline"
	var expiry := Timer.new()
	expiry.name = "ReviewExpiry"
	expiry.one_shot = true
	# At least a frame, so a request drained with a sliver left still shows.
	expiry.wait_time = maxf(0.001, timeout_ms / 1000.0)
	expiry.timeout.connect(func(): _expire_plugin_review(id))
	add_child(expiry)
	expiry.start()
	_pending_plugin_reviews[id] = {"dialog": dialog, "timer": expiry}

	dialog.confirmed.connect(func():
		# Consent made once counts: the accepted plugin is recorded at its
		# pinned revision with the spawn plans the review listed, so installed
		# content does not re-prompt forever (and a *new* revision re-prompts —
		# the record keys on the pin, while profiles whose tiles change under
		# it re-prompt because their plans are no longer covered).
		TrustedStore.approve_plugin(
			str(params.get("id", "")), str(params.get("revision", "")),
			PluginReviewText.plans(params))
		if not replaces.is_empty():
			_pending_profile_replacements[str(params.get("id", ""))] = replaces.duplicate()
		_finish_plugin_review(id)
		send_ipc_answer.call(id, true, JSON.stringify({"accepted": true}))
		# The CLI only moves the clone into place after it reads this answer,
		# so the installed profiles and concepts are not on disk yet — pick
		# them up once they are (same wait the deferred concept push uses).
		_refresh_plugin_content_deferred()
	)
	dialog.canceled.connect(func():
		_finish_plugin_review(id)
		send_ipc_answer.call(id, true, JSON.stringify({"accepted": false}))
	)
	AppDialog.popup(dialog)

## Drop a pending review's dialog and expiry timer (idempotent — the answer
## path and the expiry path both land here).
func _finish_plugin_review(id: int):
	var entry = _pending_plugin_reviews.get(id)
	_pending_plugin_reviews.erase(id)
	if not (entry is Dictionary):
		return
	var dialog = entry.get("dialog")
	if dialog != null and is_instance_valid(dialog):
		dialog.queue_free()
	var timer = entry.get("timer")
	if timer != null and is_instance_valid(timer):
		timer.queue_free()

## The request's fallback deadline passed. Nothing is answered — by the time
## this fires the request is gone, which is what the timer's deadline means.
func _expire_plugin_review(id: int):
	if not _pending_plugin_reviews.has(id):
		return
	_finish_plugin_review(id)
	ToastManager.warn(
		"Plugin install review expired — the requesting command already timed out. Nothing was installed.",
		8.0)

## The deferred answers' refusal (`_poll_pending_waits`,
## `_send_held_pane_answer`, `_show_plugin_review`). All three name app state —
## a pane that went away, a child that never started, too many open reviews —
## so there is no code parameter: `WorkspaceIpcHandlers.refused` is the kind,
## and nothing here is a caller's bad value.
func _ipc_error(msg: String) -> Dictionary:
	return WorkspaceIpcHandlers.refused(msg)

## Resolve an IPC pane target to the pane it names.
##
## A target is either an `attachment_id` (the public id, unique across every
## workspace) or a display label ("T1"). Labels are numbered per workspace and
## restart at 1, so two workspaces routinely hold a "T1": resolving that label
## to the active workspace's pane would hand an agent's command to a pane it
## never named - the user switching tabs while an agent works in the
## background is ordinary use, not an edge case. So an id always wins (it
## cannot be ambiguous), a label that matches exactly one pane in one
## workspace still resolves, and a label that matches several is refused.
##
## Returns `{body: Control}` on success, `{error: String, code: int}` when the
## target names nothing or names several panes; the refusal lists every
## candidate's workspace and attachment id, which is what the caller needs to
## address the pane it meant. The code is the refusal's JSON-RPC kind, decided
## here so no handler re-decides it: a missing target is a malformed request
## (`-32602`), an unknown or ambiguous one is app state (`-32000`).
func _resolve_pane_target(target: String) -> Dictionary:
	if target == "":
		return {
			"error": "Pane target required",
			"code": WorkspaceIpcHandlers.CODE_INVALID_PARAMS,
		}
	for ws in _workspaces:
		if ws.is_empty() or not ws.has("tm"):
			continue
		for t in ws.tm.tiles:
			var body = ws.tm._find_body(t.wrapper)
			if body != null and str(body.get("attachment_id")) == target:
				return {"body": body}
	var matches: Array = []
	for ws in _workspaces:
		if ws.is_empty() or not ws.has("tm"):
			continue
		for t in ws.tm.tiles:
			var body = ws.tm._find_body(t.wrapper)
			if body == null or str(body.get("pane_label")) != target:
				continue
			matches.append({"body": body, "workspace": str(ws.name)})
	if matches.size() == 1:
		return {"body": matches[0]["body"]}
	if matches.is_empty():
		return {
			"error": "Pane '%s' not found" % target,
			"code": WorkspaceIpcHandlers.CODE_SERVER_ERROR,
		}
	var candidates: Array[String] = []
	for hit in matches:
		candidates.append("%s (%s)" % [hit["workspace"], str(hit["body"].attachment_id)])
	return {
		"error": "Pane '%s' is ambiguous: it names %s - address the pane by its id" % [
			target, ", ".join(candidates),
		],
		"code": WorkspaceIpcHandlers.CODE_SERVER_ERROR,
	}

## The global settings panel, created on first use. Extracted from
## `_toggle_settings` so a palette command can open the panel on one of its
## tabs instead of toggling it blind.
func _ensure_settings_panel() -> SettingsPanel:
	if _settings_panel == null:
		_settings_panel = SettingsPanel.new(self)
		_settings_panel.name = "SettingsPanel"
		_settings_panel.visible = false
		_settings_panel.z_index = 100
		add_child(_settings_panel)
		_settings_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_settings_panel.request_graph_editor.connect(_open_concept_graph)
		_settings_panel.keyboard_released.connect(
			_on_overlay_keyboard_released.bind(_settings_panel))
	return _settings_panel

func _toggle_settings():
	var settings := _ensure_settings_panel()
	if settings.visible:
		settings.close()
		return
	_raise_settings_panel(settings)
	settings.open()

## The palette's "Save Command…": the settings panel on its Commands tab with
## the add form already open. Opening, never toggling — the user asked for that
## tab, so a second palette run must not close what it just opened.
func _open_commands_settings() -> void:
	var settings := _ensure_settings_panel()
	_raise_settings_panel(settings)
	settings.open_commands(true)

## The palette's "Keyboard Shortcuts": the About tab, where the list lives.
## The panel reads the registry when it opens, so a chord rebound since the last
## look is spelled as it is now.
func _open_shortcuts_settings() -> void:
	var settings := _ensure_settings_panel()
	_raise_settings_panel(settings)
	settings.open_about()

## Put the settings panel in front and close the pane settings overlay, so the
## two overlays never stack. Input picking uses reverse tree order (z_index is
## rendering-only), so the panel has to stay topmost even when workspaces were
## added after its first open.
func _raise_settings_panel(settings: SettingsPanel) -> void:
	var panel: Control = _tm._pane_settings_panel
	if panel and panel.visible:
		panel.close()
	move_child(settings, -1)

## Open the visual concept editor over the settings panel it was launched
## from. Created lazily; `open()` reloads the canvas, so an edit made in the
## manual dialog shows up when the editor is next opened.
func _open_concept_graph():
	if _concept_graph == null:
		_concept_graph = ConceptGraphEditor.new()
		_concept_graph.name = "ConceptGraphEditor"
		_concept_graph.visible = false
		_concept_graph.z_index = 100
		add_child(_concept_graph)
		_concept_graph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_concept_graph.keyboard_released.connect(
			_on_overlay_keyboard_released.bind(_concept_graph))
	# Input picking uses reverse tree order (z_index is rendering-only); stay
	# topmost over workspaces added after the first open.
	move_child(_concept_graph, -1)
	_concept_graph.open()

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


## Push the merged concept set once the scene tree has settled (GDExtension
## and terminal nodes ready). The push itself lives in `ConceptManager`: the
## store is process-wide, so the scan this used to do only existed to borrow a
## terminal's instance as the FFI vehicle — and it silently skipped the push
## when no terminal was open.
func _push_concepts_deferred():
	await get_tree().create_timer(2.0).timeout
	# The workspace may have been torn down (tests, quick quit) while waiting;
	# resuming on a freed instance would raise a script error.
	if not is_instance_valid(self) or not is_inside_tree():
		return
	ConceptManager._push_to_rust()

## Re-read the installed plugins' content — profiles and concepts — once the
## CLI has had time to move the accepted clone into place and write its store
## record. Called from the install review's accept path; refreshing
## immediately would read the store before the install exists.
func _refresh_plugin_content_deferred():
	await get_tree().create_timer(2.0).timeout
	# The workspace may have been torn down (tests, quick quit) while waiting;
	# resuming on a freed instance would raise a script error.
	if not is_instance_valid(self) or not is_inside_tree():
		return
	ProfileManager.refresh_plugin_profiles()
	ConceptManager.refresh_plugin_concepts()
	_apply_pending_profile_replacements()

## A plugin install was accepted with one or more same-name user profiles.
## Delete them only after the plugin's store record is visible and only for
## names the installed plugin actually ships; a failed install (or a store
## that has not caught up) therefore leaves every user profile intact.
func _apply_pending_profile_replacements():
	if _pending_profile_replacements.is_empty():
		return
	var pending := _pending_profile_replacements.duplicate()
	_pending_profile_replacements.clear()
	for plugin_id in pending:
		var names = pending[plugin_id]
		if not (names is Array):
			continue
		var shipped := ProfileManager.raw_plugin_profile_names(str(plugin_id))
		if shipped.is_empty():
			continue
		var kept: Array[String] = []
		for name in names:
			if not (name is String):
				continue
			if shipped.has(name) and ProfileManager.find_user_profile(name) >= 0:
				kept.append(name)
		if kept.is_empty():
			continue
		var removed := ProfileManager.delete_profiles_named(kept)
		if removed.is_empty():
			continue
		for ws in _workspaces:
			if removed.has(str(ws.get("profile", ""))):
				ws["profile"] = ""
		if removed.has(_active_profile):
			_active_profile = ""
		ToastManager.info("Replaced profile(s) with the plugin's version: %s" % ", ".join(removed))
		_refresh_profile_buttons()

func get_terminal_for_ffi() -> GptyTerminal:
	for t in _tm.tiles:
		var body = _tm._find_body(t.wrapper)
		if body and body._terminal:
			return body._terminal
	return null

func _prune_history_deferred():
	# Wait for the scene tree to fully settle (GDExtension + terminal nodes ready)
	await get_tree().create_timer(2.0).timeout
	# The workspace may have been torn down (tests, quick quit) while waiting;
	# resuming on a freed instance would raise a script error.
	if not is_instance_valid(self) or not is_inside_tree():
		return
	# Skip in editor and headless GUT runs: a test workspace holds a handful of
	# throwaway pane ids, and this sweep deletes every row for ids outside the
	# live set — against the real history database that would reclaim the
	# user's scrollback as collateral. Same gate the update checker uses.
	if OS.has_feature("editor"):
		return
	# At most one sweep per session: the history connection sees the whole
	# database, so a single call reclaims every orphaned pane's rows.
	if _history_pruned:
		return
	_history_pruned = true
	# Any live terminal works as the FFI handle — the prune is global.
	var term = get_terminal_for_ffi()
	if term == null:
		return
	var ids: Array[String] = []
	for ws in _workspaces:
		if ws.is_empty() or not ws.has("tm"):
			continue
		for t in ws.tm.tiles:
			var body = ws.tm._find_body(t.wrapper)
			if body == null:
				continue
			var id: String = str(body.get("attachment_id"))
			if id.is_empty():
				continue
			ids.append(id)
	term.prune_history(JSON.stringify(ids))

## The one same-name confirmation used by Save Profile and the sidebar's
## rename. Callers hide their own dialog first when one is open; this helper
## only owns the question and its callbacks.
func _confirm_replace_profile(profile_name: String, on_replace: Callable, on_cancel := Callable()):
	var dialog := AppDialog.confirm(self, "Replace Profile")
	AppDialog.set_text(dialog,
		"A profile named '%s' already exists. Replace it?" % A11y.one_line(profile_name))
	dialog.ok_button_text = "Replace"
	dialog.cancel_button_text = "Cancel"
	dialog.confirmed.connect(func():
		on_replace.call()
		dialog.queue_free()
	)
	dialog.canceled.connect(func():
		if on_cancel.is_valid():
			on_cancel.call()
		dialog.queue_free()
	)
	AppDialog.popup(dialog)

func _save_current_as_profile():
	# Gather current tiles
	var ts = _gather_tiles()

	if ts.is_empty():
		ToastManager.warn("No panes to save")
		return

	# Build save dialog
	var dialog := AppDialog.confirm(self, "Save Profile")
	dialog.ok_button_text = "Save"
	dialog.cancel_button_text = "Cancel"

	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", UiTokens.SPACE_MD)
	AppDialog.content(dialog).add_child(v)

	var name_label = Label.new(); name_label.text = "Profile name:"
	v.add_child(name_label)
	var name_inp = LineEdit.new(); name_inp.placeholder_text = "My Profile"
	name_inp.custom_minimum_size.x = 320
	v.add_child(name_inp)

	var panes_label = Label.new(); panes_label.text = "Pane commands (edit to customize):"
	v.add_child(panes_label)
	# The form's widths are the dialog's widths: a ScrollContainer reports only
	# its own minimum, so the rows below it were laid out at the LineEdit's
	# 69 px minimum and `/bin/bash` clipped to `/bin/ba` (measured 2026-11-03 on
	# a 316 px dialog). Each row now carries a real minimum instead.
	var sc = ScrollContainer.new()
	sc.custom_minimum_size = Vector2(340, 200)
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
		le.custom_minimum_size = Vector2(220, 0)
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
		var existing := ProfileManager.find_user_profile(profile_name)
		if existing >= 0:
			dialog.hide()
			_confirm_replace_profile(profile_name, func():
				var current := ProfileManager.find_user_profile(profile_name)
				if current >= 0:
					ProfileManager.update_profile(current, profile_name, ts)
					ToastManager.info("Profile '%s' replaced" % profile_name)
				else:
					var stored := ProfileManager.add_profile(profile_name, ts)
					ToastManager.info("Profile '%s' saved" % stored)
				dialog.queue_free()
			, func():
				if is_instance_valid(dialog):
					AppDialog.popup(dialog)
					name_inp.grab_focus()
			)
			return
		var stored := ProfileManager.add_profile(profile_name, ts)
		ToastManager.info("Profile '%s' saved" % stored)
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)

	AppDialog.popup(dialog)
	# Disable OK initially (empty name)
	name_inp.text_changed.emit("")

func _activate_profile(p_name: String):
	var profile := ProfileManager.find_profile(p_name)
	if profile.is_empty():
		return

	# Workspace trust: a profile can change the program, its arguments, and its
	# environment. All three go through the same gate as the workspace restore
	# — with the consent memory applied: content the user already approved
	# (a builtin at this app version, or a profile whose every untrusted
	# spawn plan an approval covers) activates without re-asking.
	var profile_tiles := _profile_tiles(profile)

	if _tiles_untrusted(profile_tiles):
		if _profile_consented(profile):
			_do_profile_activate(profile)
			return
		_show_profile_trust_dialog(profile, profile_tiles)
		return

	_do_profile_activate(profile)

## The profile section's second gesture: open `p_name` in a workspace of its
## own and leave the active workspace untouched. Because nothing live is
## replaced, the "replace your layout?" confirmation is skipped — but the
## Workspace Trust gate is not: the profile still chooses programs to spawn.
## Refused at the workspace cap before consent, so the user is not asked to
## approve a profile that then cannot open.
func _open_profile_in_new_workspace(p_name: String):
	var profile := ProfileManager.find_profile(p_name)
	if profile.is_empty():
		return
	if _workspaces.size() >= MAX_WORKSPACES:
		ToastManager.warn("Maximum %d workspaces" % MAX_WORKSPACES)
		return
	var profile_tiles := _profile_tiles(profile)
	if _tiles_untrusted(profile_tiles):
		if _profile_consented(profile):
			_do_activate(profile, true, true)
			return
		_show_profile_trust_dialog(profile, profile_tiles, true)
		return
	_do_activate(profile, true, true)

## A profile's tiles as a typed array. `tiles` is untyped JSON at every entry
## point (the user file, a plugin record, the sidebar dictionary), so the
## conversion lives in one place instead of in each activation path.
func _profile_tiles(profile: Dictionary) -> Array[Dictionary]:
	var tiles: Array[Dictionary] = []
	for td in profile.get("tiles", []):
		if td is Dictionary:
			tiles.append(td)
	return tiles

## `open_in_new` is carried through the consent step: the user approves the
## profile's programs once, and the approval must not silently redirect the
## click into the current workspace (or the other way round).
func _show_profile_trust_dialog(profile: Dictionary, tiles: Array, open_in_new := false):
	var dialog := AppDialog.confirm(self, "Workspace Trust")
	var details_tiles: Array[Dictionary] = []
	for td in tiles:
		if td is Dictionary:
			details_tiles.append(td)
	var details := _untrusted_details(details_tiles, _spawn_cwd(_active_workspace()))
	AppDialog.set_body(dialog, "This profile contains panes that start a different program or pass extra arguments than your current default shell (%s).\n\n%s\n\nDo you want to activate it anyway?" % [SettingsManager.cfg_shell_command, details])
	dialog.ok_button_text = "Activate"
	dialog.cancel_button_text = "Cancel"
	dialog.confirmed.connect(func():
		_remember_profile_consent(profile, details_tiles)
		_do_activate(profile, true, open_in_new)
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	AppDialog.popup(dialog)

func _do_profile_activate(profile: Dictionary):
	# Confirm if workspace has existing panes
	if _tm.tiles.size() > 0:
		var dialog := AppDialog.confirm(self, "Activate Profile")
		AppDialog.set_text(dialog, "Activating a profile will replace your current layout. Continue?")
		dialog.ok_button_text = "Activate"
		dialog.cancel_button_text = "Cancel"
		dialog.confirmed.connect(func():
			_do_activate(profile)
			dialog.queue_free()
		)
		dialog.canceled.connect(dialog.queue_free)
		AppDialog.popup(dialog)
	else:
		_do_activate(profile)

## Activate `profile` where the caller chose: `open_in_new` creates a
## workspace for it and switches there (so the reset and the restore run
## against that tab), otherwise it replaces the active workspace's layout.
## `ask_running` is false only for an IPC action, whose caller cannot answer a
## dialog and was already refused for unsaved work; a new workspace has no live
## panes, so that walk is skipped for the new-workspace branch.
func _do_activate(profile: Dictionary, ask_running := true, open_in_new := false):
	if open_in_new:
		var fresh := _create_workspace_for_profile(profile)
		if fresh.is_empty():
			return
		_activate_now(fresh, profile)
		return
	var ws := _active_workspace()
	if ws.is_empty():
		# A profile is an explicit "give me this layout": with no workspace to
		# replace, create the default one and activate into it.
		_add_workspace()
		ws = _active_workspace()
	if ws.is_empty():
		return
	_ask_close_then(
		_pane_bodies(ws), func(): _activate_now(ws, profile), Callable(), ask_running,
		"Activating the '%s' profile" % A11y.one_line(str(profile.get("name", ""))))

func _activate_now(ws: Dictionary, profile: Dictionary):
	_reset_now()
	var raw: Array = TerminalManager.scale_layout(
		profile.get("tiles", []), int(profile.get("grid_unit", 0)))
	var tiles: Array[Dictionary] = []
	for td in raw:
		if td is Dictionary:
			tiles.append(td)
	_restore_into(ws, tiles)
	ws["profile"] = str(profile.get("name", ""))
	# Same refresh path as workspace switching: layout, pane list, titlebars,
	# focus, and the profile accent, which is re-derived from `ws` (never
	# carried across a switch).
	_apply_active_workspace_view()
	ToastManager.info("Profile '%s' activated" % profile.get("name", ""))

## The sidebar's plugin-profile trash. The FFI removes the plugin record and
## its directories; this clears the accents of the profiles it provided,
## refreshes the sidebar and the engine's plugin concepts, and reports the
## result. Live panes stay: uninstalling removes the template, not the work.
func _uninstall_profile_plugin(plugin_id: String):
	var removed: Array[String] = []
	for profile in ProfileManager.get_all_profiles():
		if profile.get("plugin", false) == true \
				and str(profile.get("plugin_id", "")) == plugin_id:
			removed.append(str(profile.get("name", "")))
	var result := ProfileManager.uninstall_plugin(plugin_id)
	if not bool(result.get("ok", false)):
		ToastManager.warn("Could not uninstall plugin '%s': %s" % [
			plugin_id, str(result.get("error", ""))])
		return
	for ws in _workspaces:
		if removed.has(str(ws.get("profile", ""))):
			ws["profile"] = ""
	if removed.has(_active_profile):
		_active_profile = ""
	ProfileManager.refresh_plugin_profiles()
	ConceptManager.refresh_plugin_concepts()
	var warnings = result.get("warnings", [])
	if warnings is Array and not warnings.is_empty():
		ToastManager.warn("Uninstalled plugin '%s'; some files could not be removed: %s" % [
			plugin_id, ", ".join(warnings)])
	else:
		ToastManager.info("Uninstalled plugin '%s' (%d profile(s) removed)" % [
			plugin_id, removed.size()])

func _delete_profile(idx: int):
	# The sidebar's index is a user-profile index (the `_user_index` it
	# received), so it addresses `get_profiles()` — `get_all_profiles()` puts
	# the built-in and installed-plugin profiles in front of it.
	var profiles := ProfileManager.get_profiles()
	var deleted_name := ""
	if idx >= 0 and idx < profiles.size():
		deleted_name = str(profiles[idx].get("name", ""))
	ProfileManager.delete_profile(idx)
	for ws in _workspaces:
		if str(ws.get("profile", "")) == deleted_name:
			ws["profile"] = ""
	if deleted_name != "" and deleted_name == _active_profile:
		_active_profile = ""
	_refresh_profile_buttons()
	ToastManager.info("Profile deleted")

func _rename_profile(idx: int, new_name: String):
	# Same index space as the sidebar's rows: user profiles only.
	var profiles := ProfileManager.get_profiles()
	if idx < 0 or idx >= profiles.size():
		return
	var old_name := str(profiles[idx].get("name", ""))
	var trimmed := new_name.strip_edges()
	var target := -1
	if trimmed != "":
		target = ProfileManager.find_user_profile(trimmed)
	if target >= 0 and target != idx:
		_confirm_replace_profile(trimmed, func():
			_apply_profile_rename(idx, old_name, trimmed, true)
		, func():
			# The inline editor committed; rebuilding the row puts the
			# original name back after a cancel.
			_refresh_profile_buttons()
		)
		return
	_apply_profile_rename(idx, old_name, new_name, false)

func _apply_profile_rename(idx: int, old_name: String, new_name: String, replace_existing: bool):
	# The sidebar's index can be stale after an IPC save; the old name is the
	# stable identity the user pointed at.
	var current := ProfileManager.find_user_profile(old_name)
	if current < 0:
		_refresh_profile_buttons()
		return
	idx = current
	var replaced_name := new_name.strip_edges() if replace_existing else ""
	var renamed := ProfileManager.rename_profile(idx, new_name, replace_existing)
	if renamed == "":
		ToastManager.warn("Cannot rename profile")
		_refresh_profile_buttons()
		return
	for ws in _workspaces:
		if replace_existing and str(ws.get("profile", "")) == replaced_name:
			ws["profile"] = ""
		elif str(ws.get("profile", "")) == old_name:
			ws["profile"] = renamed
	if replace_existing and _active_profile == replaced_name:
		_active_profile = ""
	elif old_name != "" and _active_profile == old_name:
		_active_profile = renamed
	if replace_existing:
		ToastManager.info("Profile '%s' replaced by '%s'" % [replaced_name, renamed])
	else:
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
