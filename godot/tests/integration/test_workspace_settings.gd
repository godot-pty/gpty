extends GutTest
# Integration tests: workspace-level settings consistency.
# Defends the fix for pane titlebars and terminal settings being
# dropped on profile activation and post-startup spawns.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_show_titlebar = false
	SettingsManager.cfg_shell_command = "/bin/sh"
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	SettingsManager.cfg_font_size = 17
	SettingsManager.cfg_cursor_shape = 1

func after_each():
	# Free synchronously while mocks are still active: _exit_tree() → _save()
	# would otherwise write the real layout/settings after teardown restores
	# the real persistence scripts.
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

func test_startup_spawn_gets_global_settings():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	assert_gt(tm.tiles.size(), 0, "workspace should spawn a terminal on empty layout")
	var body = tm._find_body(tm.tiles[0].wrapper)
	assert_eq(body.font_size, 17, "spawned terminal should get cfg font size")
	assert_eq(body.cursor_shape, 1, "spawned terminal should get cfg cursor shape")
	var tb = tm.tiles[0].wrapper.get_node_or_null("BodyVBox/TitleBar")
	assert_false(tb.visible, "spawned titlebar should be hidden when cfg_show_titlebar is false")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_profile_activation_respects_show_titlebar():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._do_activate({"name": "P", "tiles": [{
		"col": 0, "row": 0, "cspan": 12, "rspan": 12,
		"settings": {"type": "terminal", "shell": "/bin/sh", "rows": 24, "cols": 80},
	}]})
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	assert_eq(tm.tiles.size(), 1, "profile activation should replace the layout")
	var tb = tm.tiles[0].wrapper.get_node_or_null("BodyVBox/TitleBar")
	assert_not_null(tb, "titlebar node should exist")
	assert_false(tb.visible, "profile-activated titlebar should be hidden when cfg_show_titlebar is false")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_click_activates_non_terminal_pane():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._do_activate({"name": "P", "tiles": [
		{"col": 0, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "code_viewer", "pane_name": "C1"}},
		{"col": 6, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "terminal", "shell": "/bin/sh", "rows": 24, "cols": 80}},
	]})
	await get_tree().process_frame
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	var terminal_body = null
	var viewer_body = null
	for t in tm.tiles:
		var b = tm._find_body(t.wrapper)
		if b is TerminalPane:
			terminal_body = b
		else:
			viewer_body = b
	assert_not_null(terminal_body)
	assert_not_null(viewer_body)

	# A click inside the code viewer's wrapper must make it the active pane.
	var w0: Control = tm.tiles[0].wrapper
	var ev = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = w0.get_global_rect().get_center()
	ws._input(ev)

	assert_eq(tm.last_body, viewer_body,
		"clicking a non-terminal pane must make it the active pane")

	# A click on the terminal must make it active again.
	var w1: Control = tm.tiles[1].wrapper
	ev.position = w1.get_global_rect().get_center()
	ws._input(ev)
	assert_eq(tm.last_body, terminal_body,
		"clicking the terminal must make it the active pane")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_add_workspace_starts_blank():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._add_workspace()
	assert_eq(ws._workspaces.size(), 2, "add_workspace must create a second workspace")
	var new_ws: Dictionary = ws._workspaces[1]
	assert_eq((new_ws.tm as TerminalManager).tiles.size(), 0,
		"a new workspace must be a blank slate — no auto-spawned terminal")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_pane_run_executes_through_configured_shell():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	var result = WorkspaceIpcHandlers.handle(ws, "paneRun", {"command": "echo hi && exit 7"})
	assert_true(result is Dictionary and result.has("pane_id"), "paneRun must return a pane id")

	var tm: TerminalManager = ws._tm
	var body = null
	for t in tm.tiles:
		var b = tm._find_body(t.wrapper)
		if b is TerminalPane and b.attachment_id == str(result.get("pane_id", "")):
			body = b
			break
	assert_not_null(body, "paneRun must spawn a terminal pane")
	assert_eq(body.shell_command, SettingsManager.cfg_shell_command,
		"paneRun must use the configured shell as the program")
	assert_eq(body.shell_args, ["-c", "echo hi && exit 7"],
		"the command must run as shell arguments, not the program")

	var err = WorkspaceIpcHandlers.handle(ws, "paneRun", {"command": "   "})
	assert_true(err is Dictionary and err.has("error"), "empty command must error")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_ui_colors_apply_live_to_existing_wrappers():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	var wrapper: PanelContainer = tm.tiles[0].wrapper
	var sb = wrapper.get_theme_stylebox("panel") as StyleBoxFlat
	assert_not_null(sb, "wrapper must carry a panel stylebox")
	assert_eq(sb.bg_color, SettingsManager.cfg_wrapper_bg,
		"startup must apply the configured wrapper bg")

	# save_settings() emits settings_changed → workspace must re-apply the
	# chrome colors to existing panes (no app restart required).
	SettingsManager.cfg_wrapper_bg = Color(0.9, 0.1, 0.1)
	SettingsManager.cfg_title_bar_bg = Color(0.1, 0.9, 0.1)
	SettingsManager.cfg_sidebar_bg = Color(0.1, 0.1, 0.9)
	SettingsManager.save_settings()

	assert_eq(sb.bg_color, Color(0.9, 0.1, 0.1),
		"wrapper bg must update live on existing panes")
	var tb = wrapper.get_node_or_null("BodyVBox/TitleBar")
	var tbg = tb.get_node_or_null("TitleBarBg")
	assert_not_null(tbg, "pane titlebar must carry a named bg rect")
	assert_eq(tbg.color, Color(0.1, 0.9, 0.1),
		"pane titlebar bg must update live on existing panes")
	assert_eq(ws._sidebar_bg.color, Color(0.1, 0.1, 0.9),
		"sidebar bg must update live")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_pane_status_includes_agent_state():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	var run = WorkspaceIpcHandlers.handle(ws, "paneRun", {"command": "echo hi"})
	assert_true(run is Dictionary and run.has("pane_id"), "paneRun must return a pane id")
	var st = WorkspaceIpcHandlers.handle(ws, "paneStatus", {"pane_id": str(run.get("pane_id"))})
	assert_true(st is Dictionary and not st.has("error"), "paneStatus must succeed")
	assert_true(st.has("agent_state"), "paneStatus must expose agent_state")
	assert_eq(str(st.get("agent_state", "")), "idle",
		"a fresh terminal must report idle agent state")
	assert_true(st.has("agent_state_tier"), "paneStatus must expose the detection tier")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_pane_settings_open_above_second_workspace_grid():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._add_workspace()
	assert_eq(ws._workspaces.size(), 2, "add_workspace must create a second workspace")
	var body = ws._spawn_pane("terminal")
	assert_not_null(body, "spawning into the second workspace must work")

	ws._tm._open_pane_settings(body)
	var panel = ws._tm._pane_settings_panel
	assert_true(panel.visible, "pane settings popup must open on a non-first workspace")
	assert_gt(panel.z_index, ws._grid.z_index,
		"overlay panels must render above later-added workspace grids")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_search_button_opens_active_terminal_search():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._open_active_search()
	var tm: TerminalManager = ws._tm
	var body = tm._find_body(tm.tiles[0].wrapper)
	assert_true(body is TerminalPane, "startup must spawn a terminal")
	assert_true(body._search_visible, "search button must open the terminal search UI")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_search_bar_is_compact_bottom_strip():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	var body = tm._find_body(tm.tiles[0].wrapper)
	assert_true(body is TerminalPane, "startup must spawn a terminal")
	body._toggle_search()
	await get_tree().process_frame

	# Regression: a missing anchor_top made every search control stretch to
	# full pane height — the bar covered the whole terminal as an overlay.
	assert_gt(body._search_bar.size.y, 20.0, "search bar must have real height")
	assert_lt(body._search_bar.size.y, 50.0, "search bar must be a compact strip, not a full-pane overlay")
	assert_lt(body._scope_btn.size.y, 50.0, "scope button must be a compact strip")
	assert_lt(body._history_panel.size.y, 250.0, "results panel must be bounded above the bar")
	assert_gt(body._search_bar.size.x, 400.0, "search bar must span most of the pane width")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_profile_activation_refreshes_layout_and_pane_list():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)  # give layout math a real viewport
	await get_tree().process_frame
	await get_tree().process_frame

	ws._do_activate({"name": "P", "tiles": [
		{"col": 0, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "code_viewer", "pane_name": "C1"}},
		{"col": 6, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "terminal", "shell": "/bin/sh", "rows": 24, "cols": 80}},
	]})
	await get_tree().process_frame
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	assert_eq(tm.tiles.size(), 2, "activation should restore two panes")
	# Regression: the pane list must populate immediately — no workspace
	# switch-and-back required.
	assert_eq(ws._sidebar._pane_list.get_child_count(), 2,
		"pane list must reflect the activated profile immediately")
	# Regression: wrappers must be laid out (not squished at the origin).
	var w0: Control = tm.tiles[0].wrapper
	assert_gt(w0.offset_right - w0.offset_left, 100.0,
		"activated wrapper must be laid out with real width")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout


func test_killing_the_focused_pane_hands_focus_to_a_survivor():
	# Closing the active pane used to leave keyboard focus unowned: the freed
	# node released it, last_body went null, and typing reached nothing until
	# the user clicked a pane.
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame

	var victim = ws._spawn_pane("terminal")
	assert_not_null(victim)
	victim.grab_focus()
	await get_tree().process_frame
	ws._tm.last_body = victim
	assert_true(victim.has_focus(), "precondition: the pane to close holds focus")

	ws._kill(victim)
	await get_tree().process_frame
	await get_tree().process_frame

	var survivor = ws._tm.last_body
	assert_not_null(survivor, "some pane must hold focus after the active one is closed")
	assert_true(is_instance_valid(survivor))
	assert_ne(survivor, victim, "focus must not stay on the closed pane")
	assert_true(survivor is TerminalPane, "only terminals take keyboard focus")
	assert_true(survivor.has_focus(), "the surviving terminal must hold keyboard focus")

	await get_tree().create_timer(2.1).timeout


func test_restore_renames_duplicate_attachment_ids():
	# Every pane is addressed over IPC by attachment_id and resolution returns
	# the first match, so a saved layout naming one id twice would make inject,
	# read, status, wait, kill and focus all silently act on the same pane.
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._build_workspaces([
		{"name": "W1", "layout": [
			{"col": 0, "row": 0, "cspan": 6, "rspan": 12,
			 "settings": {"type": "terminal", "attachment_id": "shared-id"}},
			{"col": 6, "row": 0, "cspan": 6, "rspan": 12,
			 "settings": {"type": "terminal", "attachment_id": "shared-id"}},
		]},
	], 0)

	var ids: Array = []
	for t in ws._tm.tiles:
		var body = ws._tm._find_body(t.wrapper)
		if body:
			ids.append(body.attachment_id)
	assert_eq(ids.size(), 2, "both saved tiles must restore")
	assert_ne(ids[0], ids[1], "duplicate attachment_ids must be made unique")
	assert_eq(ids[0], "shared-id", "the first pane keeps the saved id")
	assert_ne(ids[1], "", "the renamed pane must still have an id")

	await get_tree().create_timer(2.1).timeout

## A restored layout must end up the same *size on screen* as it was saved.
##
## The grid unit is a single constant (PaneTypes.GRID) read by the drag math,
## the sanitizer, and `_apply_layout`; when a second copy of it drifted, the
## sanitizer clamped a half-width tile to a single cell and the layout divided
## by the wrong unit, so the restored panes were sized several times the grid
## and drew outside the visible area. Asserting spans alone misses that: the
## wrappers' rects are what the user sees.
func test_restored_layout_keeps_its_share_of_the_screen():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	# A legacy (12-unit) two-pane profile: the migration must scale it.
	ws._do_activate({"name": "P", "tiles": [
		{"col": 0, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "code_viewer", "pane_name": "C1"}},
		{"col": 6, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "terminal", "shell": "/bin/sh", "rows": 24, "cols": 80}},
	]})
	await get_tree().process_frame
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	assert_eq(tm.tiles.size(), 2, "the profile must restore both panes")
	var grid: Control = ws._grid
	var left: Rect2 = (tm.tiles[0].wrapper as Control).get_global_rect()
	var right: Rect2 = (tm.tiles[1].wrapper as Control).get_global_rect()
	assert_almost_eq(left.size.x, grid.size.x * 0.5, grid.size.x * 0.02,
		"a half-width pane must be half the grid wide, not a multiple of it")
	assert_almost_eq(left.size.x + right.size.x, grid.size.x, grid.size.x * 0.02,
		"the two panes must fill the grid between them")
	assert_almost_eq(right.position.x, left.position.x + left.size.x, 1.0,
		"the second pane must start where the first ends")
